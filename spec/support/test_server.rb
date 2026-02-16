# frozen_string_literal: true

# Reusable HTTP/HTTPS test server for integration tests.
#
# Uses raw TCPServer (consistent with existing property test patterns)
# to provide an echo server with configurable behavior for:
#   - Reflecting request method, path, headers, body as JSON
#   - Configurable response delays (for timeout tests)
#   - Duplicate response headers
#   - Large response bodies (for streaming tests)
#
# Usage:
#   require "support/test_server"
#
#   # HTTP server
#   server = TestServer.start
#   # ... use server.endpoint, e.g. "http://127.0.0.1:#{server.port}"
#   server.stop
#
#   # HTTPS server
#   server = TestServer.start(tls: true)
#   # ... use server.ca_cert_path for ssl_ca_bundle
#   server.stop
#
# No servers are started on require — callers must explicitly call .start.

require "socket"
require "json"
require "openssl"
require "tmpdir"

# Generates a self-signed CA and server certificate for TLS tests.
# Certificates are written to a temp directory and cleaned up on stop.
module TestServerTLS
  def setup_tls
    @tmpdir = Dir.mktmpdir("test_server_tls")
    ca_key, ca_cert = create_ca
    server_key, server_cert = create_server_cert(ca_key, ca_cert)

    @ca_cert_path = File.join(@tmpdir, "ca.pem")
    File.write(@ca_cert_path, ca_cert.to_pem)

    @ssl_context = build_ssl_context(server_key, server_cert)
    @ssl_server = OpenSSL::SSL::SSLServer.new(@server, @ssl_context)
    @ssl_server.start_immediately = true
  end

  def cleanup_tls
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  private

  def create_ca
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    configure_ca_cert(cert, key)
    sign_ca_cert(cert, key)
    [key, cert]
  end

  def configure_ca_cert(cert, key)
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=TestCA")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
  end

  def sign_ca_cert(cert, key)
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
  end

  def create_server_cert(ca_key, ca_cert)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    configure_server_cert(cert, key, ca_cert)
    sign_server_cert(cert, ca_key, ca_cert)
    [key, cert]
  end

  def configure_server_cert(cert, key, ca_cert)
    cert.version = 2
    cert.serial = 2
    cert.subject = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 3600
  end

  def sign_server_cert(cert, ca_key, ca_cert)
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = ca_cert
    cert.add_extension(ef.create_extension("subjectAltName", "IP:127.0.0.1", false))
    cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
  end

  def build_ssl_context(server_key, server_cert)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = server_cert
    ctx.key = server_key
    ctx.min_version = OpenSSL::SSL::TLS1_2_VERSION
    ctx
  end
end

# Handles parsing and responding to individual HTTP connections.
module TestServerHandler
  private

  def handle_connection(client)
    method, path, headers, body = read_request(client)
    return unless method

    path_part, params = parse_path(path)
    apply_delay(headers, params)

    echo_json = build_echo_json(method, path_part, params, headers, body)
    write_response(client, method, echo_json, headers, params)
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET, OpenSSL::SSL::SSLError
    # Client disconnected
  ensure
    client&.close
  end

  def read_request(client)
    request_line = client.gets
    return unless request_line

    method, path, = request_line.strip.split(" ", 3)
    headers, content_length = read_headers(client)
    body = content_length.positive? ? client.read(content_length) : ""
    [method, path, headers, body]
  end

  def read_headers(client)
    headers = {}
    content_length = 0
    while (line = client.gets) && line.strip != ""
      name, value = line.split(":", 2)
      next unless name && value

      headers[name.strip] = value.strip
      content_length = value.strip.to_i if name.strip.casecmp("Content-Length").zero?
    end
    [headers, content_length]
  end

  def parse_path(path)
    path_part, query_string = path.split("?", 2)
    params = parse_query(query_string)
    [path_part, params]
  end

  def parse_query(query_string)
    return {} unless query_string

    query_string.split("&").each_with_object({}) do |pair, hash|
      key, value = pair.split("=", 2)
      hash[key] = value
    end
  end

  def apply_delay(headers, params)
    delay = headers["X-Delay"]&.to_f || params["delay"]&.to_f
    sleep(delay) if delay&.positive?
  end

  def build_echo_json(method, path_part, params, headers, body)
    JSON.generate(
      "method" => method,
      "path" => path_part,
      "query" => params,
      "headers" => headers,
      "body" => body
    )
  end

  def write_response(client, method, echo_json, request_headers, params)
    body = response_body(echo_json, params)
    head = build_response_head(body, request_headers)

    client.write(head)
    write_body(client, method, body) unless method == "HEAD"
  end

  def response_body(echo_json, params)
    body_size = params["body_size"]&.to_i
    body_size&.positive? ? "x" * body_size : echo_json
  end

  def build_response_head(body, request_headers)
    head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: #{body.bytesize}\r\n"
    head += duplicate_headers(request_headers)
    head += "Connection: close\r\n\r\n"
    head
  end

  # Duplicate response headers: X-Dup-Header value format is "name:val1,val2"
  # Sends the named header once per value (as separate header lines).
  def duplicate_headers(request_headers)
    dup_spec = request_headers["X-Dup-Header"]
    return "" unless dup_spec

    dup_name, dup_values_str = dup_spec.split(":", 2)
    return "" unless dup_name && dup_values_str

    dup_values_str.split(",").map { |val| "#{dup_name.strip}: #{val.strip}\r\n" }.join
  end

  # Write body in chunks for large responses to exercise streaming.
  def write_body(client, _method, body)
    if body.bytesize > 8192
      write_chunked(client, body)
    else
      client.write(body)
    end
  end

  def write_chunked(client, body)
    written = 0
    while written < body.bytesize
      chunk_size = [8192, body.bytesize - written].min
      client.write(body[written, chunk_size])
      written += chunk_size
    end
  end
end

# A test HTTP/HTTPS server backed by raw TCPServer.
#
# Echoes request details (method, path, headers, body) as JSON.
# Supports configurable delays, duplicate response headers, and
# large response bodies via request headers and query parameters.
class TestServer
  include TestServerTLS
  include TestServerHandler

  attr_reader :port, :ca_cert_path

  # Start a test server. Returns a TestServer instance.
  #
  # @param tls [Boolean] whether to wrap connections in TLS
  # @return [TestServer]
  def self.start(tls: false)
    server = new(tls: tls)
    server.start
    server
  end

  def initialize(tls: false)
    @tls = tls
    @port = nil
    @server = nil
    @thread = nil
    @ca_cert_path = nil
    @tmpdir = nil
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    setup_tls if @tls
    @thread = Thread.new { accept_loop }
  end

  def stop
    @thread&.kill
    @server&.close
    cleanup_tls
  end

  # Convenience endpoint string for ConnectionPool.
  def endpoint
    scheme = @tls ? "https" : "http"
    "#{scheme}://127.0.0.1:#{@port}"
  end

  private

  def accept_loop
    acceptor = @tls ? @ssl_server : @server
    loop do
      client = acceptor.accept
      Thread.new(client) { |c| handle_connection(c) }
    rescue IOError, Errno::EBADF
      break
    rescue OpenSSL::SSL::SSLError
      # TLS handshake failure — expected in some tests
    end
  end
end
