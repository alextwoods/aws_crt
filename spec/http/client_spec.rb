# frozen_string_literal: true

# Unit tests for AwsCrt::Http::Client.
#
# Tests the new unified HTTP client that manages connection pools
# internally. Replaces the old ConnectionPool and ConnectionPoolManager specs.

require "socket"

RSpec.describe AwsCrt::Http::Client do
  # A minimal HTTP/1.1 server using raw TCP sockets.
  def with_echo_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets
        headers = {}
        content_length = 0
        while (line = client.gets) && line.strip != ""
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip if key
          content_length = value.strip.to_i if key&.strip&.downcase == "content-length"
        end
        body = content_length > 0 ? client.read(content_length) : ""

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

  describe ".new" do
    it "creates a client with default options" do
      client = described_class.new
      expect(client).to be_a(described_class)
    end

    it "creates a client with custom options" do
      client = described_class.new(
        max_connections: 10,
        connect_timeout_ms: 5_000,
        read_timeout_ms: 10_000,
        ssl_verify_peer: false
      )
      expect(client).to be_a(described_class)
    end
  end

  describe "#request" do
    it "sends a GET request and returns an HttpResponse" do
      with_echo_server do |port|
        client = described_class.new
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"], ["Accept", "*/*"]]

        response = client.request(endpoint, "GET", "/hello", headers)

        expect(response).to be_a(AwsCrt::Http::Response)
        expect(response.status_code).to eq(200)
        expect(response.body).to include("GET /hello")

        header_hash = response.headers.to_h { |name, value| [name.downcase, value] }
        expect(header_hash["x-custom"]).to eq("test-value")
      end
    end

    it "sends a POST request with a body" do
      with_echo_server do |port|
        client = described_class.new
        endpoint = "http://127.0.0.1:#{port}"
        headers = [
          ["Host", "127.0.0.1:#{port}"],
          ["Content-Length", "11"]
        ]

        response = client.request(
          endpoint, "POST", "/submit", headers, "hello world"
        )

        expect(response.status_code).to eq(200)
        expect(response.body).to include("POST /submit")
        expect(response.body).to include("hello world")
      end
    end

    it "streams the response body when a block is given" do
      with_echo_server do |port|
        client = described_class.new
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        chunks = []
        response = client.request(endpoint, "GET", "/stream", headers) do |chunk|
          chunks << chunk
        end

        expect(response.status_code).to eq(200)
        expect(chunks.join).to include("GET /stream")
        expect(response.headers).to be_a(Hash)
        expect(response.body).to be_nil
      end
    end

    it "raises ArgumentError for invalid endpoints" do
      client = described_class.new
      expect {
        client.request("not-a-url", "GET", "/", [["Host", "x"]])
      }.to raise_error(ArgumentError, /Invalid endpoint/)
    end

    it "raises ArgumentError for unsupported schemes" do
      client = described_class.new
      expect {
        client.request("ftp://example.com", "GET", "/", [["Host", "x"]])
      }.to raise_error(ArgumentError, /Unsupported scheme/)
    end
  end

  describe "endpoint pool reuse" do
    it "reuses the same internal pool for repeated requests to the same endpoint" do
      with_echo_server do |port|
        client = described_class.new
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        # Make two requests to the same endpoint — should reuse the pool
        r1 = client.request(endpoint, "GET", "/first", headers)
        r2 = client.request(endpoint, "GET", "/second", headers)

        expect(r1.status_code).to eq(200)
        expect(r2.status_code).to eq(200)
      end
    end
  end

  describe "frozen client" do
    it "can make requests when frozen" do
      with_echo_server do |port|
        client = described_class.new
        client.freeze

        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        response = client.request(endpoint, "GET", "/frozen", headers)
        expect(response.status_code).to eq(200)
        expect(response.body).to include("GET /frozen")
      end
    end
  end

  describe "thread safety" do
    it "handles concurrent requests from multiple threads" do
      with_echo_server do |port|
        client = described_class.new
        endpoint = "http://127.0.0.1:#{port}"
        results = Array.new(8)

        threads = 8.times.map do |i|
          Thread.new do
            response = client.request(
              endpoint, "GET", "/thread-#{i}",
              [["Host", "127.0.0.1:#{port}"]]
            )
            results[i] = [response.status_code, response.body]
          end
        end
        threads.each(&:join)

        results.each_with_index do |(status, body), i|
          expect(status).to eq(200)
          expect(body).to include("GET /thread-#{i}")
        end
      end
    end
  end
end
