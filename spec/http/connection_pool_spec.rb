# frozen_string_literal: true

# Unit tests for AwsCrt::Http::ConnectionPool.
#
# Requirements:
#   3.2 — max_connections default of 25
#   6.3 — default connect timeout of 60 seconds
#   6.4 — default read timeout of 60 seconds
#   10.2 — error hierarchy

require "socket"

RSpec.describe AwsCrt::Http::ConnectionPool do
  # A minimal HTTP/1.1 server using raw TCP sockets.
  # Accepts one request, sends a canned response, then closes.
  def with_echo_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        # Read headers until blank line
        headers = {}
        content_length = 0
        while (line = client.gets) && line.strip != ""
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip if key
          content_length = value.strip.to_i if key&.strip&.downcase == "content-length"
        end
        # Read body if present
        body = content_length > 0 ? client.read(content_length) : ""

        # Echo back the request info as the response body
        method, path, = request_line&.split(" ")
        response_body = "#{method} #{path} #{body}"

        response = "HTTP/1.1 200 OK\r\n" \
                   "Content-Length: #{response_body.bytesize}\r\n" \
                   "X-Custom: test-value\r\n" \
                   "Connection: close\r\n" \
                   "\r\n" \
                   "#{response_body}"
        client.write(response)
        client.close
      rescue IOError, Errno::EPIPE
        break
      end
    end

    yield port
  ensure
    thread&.kill
    server&.close
  end

  describe "#initialize" do
    it "creates a pool for an HTTP endpoint" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        expect(pool).to be_a(described_class)
      end
    end

    it "raises ArgumentError for invalid endpoints" do
      expect { described_class.new("not-a-url") }
        .to raise_error(ArgumentError, /Invalid endpoint/)
    end

    it "raises ArgumentError for unsupported schemes" do
      expect { described_class.new("ftp://example.com") }
        .to raise_error(ArgumentError, /Unsupported scheme/)
    end

    it "raises ArgumentError for empty host" do
      expect { described_class.new("http://") }
        .to raise_error(ArgumentError, /Empty host/)
    end
  end

  describe "#request" do
    it "sends a GET request and returns status, headers, and body" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        headers = [["Host", "127.0.0.1:#{port}"], ["Accept", "*/*"]]

        status, resp_headers, body = pool.request("GET", "/hello", headers)

        expect(status).to eq(200)
        expect(body).to include("GET /hello")

        # resp_headers is an array of [name, value] pairs
        header_hash = resp_headers.to_h { |name, value| [name.downcase, value] }
        expect(header_hash["x-custom"]).to eq("test-value")
      end
    end

    it "sends a POST request with a body" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        headers = [
          ["Host", "127.0.0.1:#{port}"],
          ["Content-Length", "11"]
        ]

        status, _resp_headers, body = pool.request(
          "POST", "/submit", headers, "hello world"
        )

        expect(status).to eq(200)
        expect(body).to include("POST /submit")
        expect(body).to include("hello world")
      end
    end

    it "streams the response body when a block is given" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        headers = [["Host", "127.0.0.1:#{port}"]]

        chunks = []
        status, resp_headers = pool.request("GET", "/stream", headers) do |chunk|
          chunks << chunk
        end

        expect(status).to eq(200)
        expect(chunks.join).to include("GET /stream")
        expect(resp_headers).to be_an(Array)
      end
    end
  end

  describe "default configuration" do
    it "creates a pool with no options (all defaults applied)" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        # Pool should be functional with default max_connections=25,
        # connect_timeout_ms=60_000, max_connection_idle_ms=60_000
        status, _, body = pool.request(
          "GET", "/defaults", [["Host", "127.0.0.1:#{port}"]]
        )
        expect(status).to eq(200)
        expect(body).to include("GET /defaults")
      end
    end

    it "creates a pool with explicit default values" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}",
          max_connections: 25,
          connect_timeout_ms: 60_000,
          max_connection_idle_ms: 60_000)
        status, _, body = pool.request(
          "GET", "/explicit-defaults", [["Host", "127.0.0.1:#{port}"]]
        )
        expect(status).to eq(200)
        expect(body).to include("GET /explicit-defaults")
      end
    end

    it "accepts custom max_connections" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}",
          max_connections: 1)
        status, _, _ = pool.request(
          "GET", "/", [["Host", "127.0.0.1:#{port}"]]
        )
        expect(status).to eq(200)
      end
    end

    it "accepts custom timeout values" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}",
          connect_timeout_ms: 5_000,
          read_timeout_ms: 10_000)
        status, _, _ = pool.request(
          "GET", "/", [["Host", "127.0.0.1:#{port}"]]
        )
        expect(status).to eq(200)
      end
    end
  end

  describe "endpoint parsing" do
    it "parses HTTP endpoint with explicit port" do
      with_echo_server do |port|
        pool = described_class.new("http://127.0.0.1:#{port}")
        status, _, _ = pool.request(
          "GET", "/", [["Host", "127.0.0.1:#{port}"]]
        )
        expect(status).to eq(200)
      end
    end

    it "parses HTTP endpoint without port (defaults to 80)" do
      # We can't easily test a real connection on port 80, but we can
      # verify the pool is created without error.
      pool = described_class.new("http://127.0.0.1")
      expect(pool).to be_a(described_class)
    end

    it "parses HTTPS endpoint without port (defaults to 443)" do
      pool = described_class.new("https://example.com")
      expect(pool).to be_a(described_class)
    end

    it "parses HTTPS endpoint with custom port" do
      pool = described_class.new("https://example.com:8443")
      expect(pool).to be_a(described_class)
    end

    it "handles case-insensitive scheme" do
      pool = described_class.new("HTTP://127.0.0.1:9999")
      expect(pool).to be_a(described_class)
    end
  end
end
