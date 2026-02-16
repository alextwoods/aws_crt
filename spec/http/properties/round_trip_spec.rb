# frozen_string_literal: true

# Feature: crt-http-client, Property 2: Request/Response Round-Trip Fidelity
#
# For any valid HTTP request (with a randomly generated method from
# {GET, POST, PUT, DELETE, PATCH, HEAD}, a random path, random headers,
# and a random body), when sent through the CRT client to a local echo
# server that reflects the request back as the response, the returned
# response body SHALL contain the original request method, path, headers,
# and body content without loss or corruption.
#
# **Validates: Requirements 4.1, 4.4, 8.2, 8.3**

require "socket"
require "json"
require "rantly"
require "rantly/rspec_extensions"

# Echo server that reflects the HTTP request back as a JSON response.
# Extracted to module level to avoid rubocop complexity warnings inside
# the RSpec block and to keep the test examples focused on assertions.
module RoundTripEchoServer
  METHODS_WITH_BODY = %w[POST PUT DELETE PATCH].freeze

  def self.start
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { accept_loop(server) }
    [server, thread, port]
  end

  def self.accept_loop(server)
    loop do
      client = server.accept
      handle(client)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # Client disconnected — continue accepting
    end
  end

  def self.handle(client)
    request_line = client.gets
    return unless request_line

    method, path, = request_line.strip.split(" ", 3)
    headers, content_length = read_headers(client)
    body = content_length.positive? ? client.read(content_length) : ""

    echo_json = JSON.generate(
      "method" => method, "path" => path,
      "headers" => headers, "body" => body
    )
    write_response(client, method, echo_json)
  ensure
    client&.close
  end

  def self.read_headers(client)
    headers = {}
    content_length = 0
    while (line = client.gets) && line.strip != ""
      name, value = line.split(":", 2)
      next unless name && value

      name = name.strip
      value = value.strip
      headers[name] = value
      content_length = value.to_i if name.casecmp("Content-Length").zero?
    end
    [headers, content_length]
  end

  def self.write_response(client, method, body_json)
    # HEAD responses must not include a body per HTTP/1.1
    head = "HTTP/1.1 200 OK\r\n" \
           "Content-Type: application/json\r\n" \
           "Content-Length: #{body_json.bytesize}\r\n" \
           "Connection: close\r\n\r\n"
    client.write(head)
    client.write(body_json) unless method == "HEAD"
  end
end

RSpec.describe "Property 2: Request/Response Round-Trip Fidelity" do
  around do |example|
    server, thread, port = RoundTripEchoServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  # Generate a random URL-safe path from alphanumeric segments.
  def random_path
    segments = rand(1..4)
    parts = segments.times.map do
      len = rand(1..12)
      len.times.map { (("a".."z").to_a + ("0".."9").to_a).sample }.join
    end
    "/#{parts.join("/")}"
  end

  # Generate random header pairs with unique names.
  def random_headers
    count = rand(0..5)
    headers = [["Host", "127.0.0.1:#{@port}"]]
    count.times do |i|
      headers << ["X-Test-#{i}-#{rand(1000..9999)}", rand(10_000..99_999).to_s]
    end
    headers
  end

  # Generate a random body string of printable ASCII.
  def random_body
    len = rand(0..256)
    len.times.map { rand(32..126).chr }.join
  end

  def make_pool
    AwsCrt::Http::ConnectionPool.new("http://127.0.0.1:#{@port}")
  end

  def assert_echo_matches(echo, method:, path:, headers:, body: nil)
    expect(echo["method"]).to eq(method),
                              "Method mismatch: sent #{method.inspect}, got #{echo["method"].inspect}"
    expect(echo["path"]).to eq(path),
                            "Path mismatch: sent #{path.inspect}, got #{echo["path"].inspect}"
    headers.each do |name, value|
      echo_value = echo["headers"][name]
      expect(echo_value).to eq(value),
                            "Header #{name.inspect}: sent #{value.inspect}, got #{echo_value.inspect}"
    end
    return unless body

    expect(echo["body"]).to eq(body),
                            "Body mismatch: sent #{body.bytesize} bytes, got #{echo["body"]&.bytesize}"
  end

  it "round-trips method, path, headers, and body for methods with bodies" do
    property_of {
      RoundTripEchoServer::METHODS_WITH_BODY.sample
    }.check(20) do |method|
      path = random_path
      headers = random_headers
      body = random_body
      request_headers = headers + [["Content-Length", body.bytesize.to_s]]

      status, _, resp_body = make_pool.request(method, path, request_headers, body)
      expect(status).to eq(200)

      echo = JSON.parse(resp_body)
      assert_echo_matches(echo, method: method, path: path, headers: headers, body: body)
    end
  end

  it "round-trips method, path, and headers for GET requests" do
    property_of {
      range(1, 100)
    }.check(20) do |_|
      path = random_path
      headers = random_headers

      status, _, resp_body = make_pool.request("GET", path, headers)
      expect(status).to eq(200)

      echo = JSON.parse(resp_body)
      assert_echo_matches(echo, method: "GET", path: path, headers: headers)
      expect(echo["body"]).to eq(""),
                               "Expected empty body for GET, got #{echo["body"].inspect}"
    end
  end

  it "round-trips method and path for HEAD requests (no response body)" do
    property_of {
      range(1, 100)
    }.check(10) do |_|
      path = random_path
      headers = random_headers

      status, _, resp_body = make_pool.request("HEAD", path, headers)
      expect(status).to eq(200)

      # HEAD responses have no body per HTTP/1.1
      expect(resp_body).to eq(""),
                            "Expected empty body for HEAD, got #{resp_body.bytesize} bytes"
    end
  end
end
