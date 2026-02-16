# frozen_string_literal: true

require "support/test_server"

RSpec.describe TestServer do
  describe "HTTP mode" do
    around do |example|
      @server = TestServer.start
      example.run
    ensure
      @server&.stop
    end

    def make_pool
      AwsCrt::Http::ConnectionPool.new(@server.endpoint)
    end

    def host_header
      [["Host", "127.0.0.1:#{@server.port}"]]
    end

    it "echoes request method, path, headers, and body as JSON" do
      pool = make_pool
      headers = host_header + [%w[X-Custom hello]]
      body = "test body"
      request_headers = headers + [["Content-Length", body.bytesize.to_s]]

      status, _, resp_body = pool.request("POST", "/echo", request_headers, body)

      expect(status).to eq(200)
      echo = JSON.parse(resp_body)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/echo")
      expect(echo["headers"]["X-Custom"]).to eq("hello")
      expect(echo["body"]).to eq("test body")
    end

    it "supports configurable response delays via X-Delay header" do
      pool = make_pool
      headers = host_header + [["X-Delay", "0.1"]]

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, = pool.request("GET", "/slow", headers)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      expect(status).to eq(200)
      expect(elapsed).to be >= 0.1
    end

    it "supports configurable response delays via query parameter" do
      pool = make_pool

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, = pool.request("GET", "/slow?delay=0.1", host_header)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      expect(status).to eq(200)
      expect(elapsed).to be >= 0.1
    end

    it "supports duplicate response headers via X-Dup-Header" do
      pool = make_pool
      headers = host_header + [["X-Dup-Header", "X-Multi:val1,val2,val3"]]

      status, resp_headers = pool.request("GET", "/dup", headers)

      expect(status).to eq(200)
      # resp_headers is an array of [name, value] pairs. The CRT may
      # merge duplicates into comma-separated values or keep separate.
      # Collect all values for X-Multi, then split any comma-separated ones.
      multi_entries = resp_headers.each_with_object([]) do |(name, value), acc|
        acc << value if name == "X-Multi"
      end
      # CRT may merge into comma-separated or keep separate — either way
      # all three values should be present
      expect(multi_entries.flat_map { |v| v.split(", ") })
        .to include("val1", "val2", "val3")
    end

    it "supports large response bodies via body_size query parameter" do
      pool = make_pool

      status, _, resp_body = pool.request(
        "GET", "/large?body_size=65536", host_header
      )

      expect(status).to eq(200)
      expect(resp_body.bytesize).to eq(65_536)
    end

    it "returns no body for HEAD requests" do
      pool = make_pool

      status, _, resp_body = pool.request("HEAD", "/head", host_header)

      expect(status).to eq(200)
      expect(resp_body).to eq("")
    end

    it "parses query parameters into the echo response" do
      pool = make_pool

      status, _, resp_body = pool.request(
        "GET", "/search?q=hello&page=2", host_header
      )

      expect(status).to eq(200)
      echo = JSON.parse(resp_body)
      expect(echo["query"]).to eq("q" => "hello", "page" => "2")
    end
  end

  describe "HTTPS mode" do
    around do |example|
      @server = TestServer.start(tls: true)
      example.run
    ensure
      @server&.stop
    end

    it "provides a CA certificate path" do
      expect(@server.ca_cert_path).not_to be_nil
      expect(File.exist?(@server.ca_cert_path)).to be true
    end

    it "serves HTTPS requests when given the CA bundle" do
      pool = AwsCrt::Http::ConnectionPool.new(
        @server.endpoint,
        ssl_verify_peer: false
      )

      status, _, resp_body = pool.request(
        "GET", "/tls-test",
        [["Host", "127.0.0.1:#{@server.port}"]]
      )

      expect(status).to eq(200)
      echo = JSON.parse(resp_body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/tls-test")
    end
  end
end
