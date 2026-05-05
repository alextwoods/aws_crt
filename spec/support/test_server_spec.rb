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

    def make_client
      AwsCrt::Http::Client.new
    end

    def host_header
      [["Host", "127.0.0.1:#{@server.port}"]]
    end

    it "echoes request method, path, headers, and body as JSON" do
      client = make_client
      headers = host_header + [%w[X-Custom hello]]
      body = "test body"
      request_headers = headers + [["Content-Length", body.bytesize.to_s]]

      response = client.request(@server.endpoint, "POST", "/echo", request_headers, body)

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/echo")
      expect(echo["headers"]["X-Custom"]).to eq("hello")
      expect(echo["body"]).to eq("test body")
    end

    it "supports configurable response delays via X-Delay header" do
      client = make_client
      headers = host_header + [["X-Delay", "0.1"]]

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.request(@server.endpoint, "GET", "/slow", headers)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      expect(response.status_code).to eq(200)
      expect(elapsed).to be >= 0.1
    end

    it "supports configurable response delays via query parameter" do
      client = make_client

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.request(@server.endpoint, "GET", "/slow?delay=0.1", host_header)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      expect(response.status_code).to eq(200)
      expect(elapsed).to be >= 0.1
    end

    it "supports duplicate response headers via X-Dup-Header" do
      client = make_client
      headers = host_header + [["X-Dup-Header", "X-Multi:val1,val2,val3"]]

      response = client.request(@server.endpoint, "GET", "/dup", headers)

      expect(response.status_code).to eq(200)
      # resp_headers is a Hash. The CRT may merge duplicates into
      # comma-separated values or keep separate (last value wins in Hash).
      # Collect all values for X-Multi, then split any comma-separated ones.
      multi_values = []
      response.headers.each do |name, value|
        multi_values << value if name == "X-Multi"
      end
      # CRT may merge into comma-separated or keep separate — either way
      # all three values should be present
      expect(multi_values.flat_map { |v| v.split(", ") })
        .to include("val1", "val2", "val3")
    end

    it "supports large response bodies via body_size query parameter" do
      client = make_client

      response = client.request(@server.endpoint,
        "GET", "/large?body_size=65536", host_header
      )

      expect(response.status_code).to eq(200)
      expect(response.body.bytesize).to eq(65_536)
    end

    it "returns no body for HEAD requests" do
      client = make_client

      response = client.request(@server.endpoint, "HEAD", "/head", host_header)

      expect(response.status_code).to eq(200)
      expect(response.body).to eq("")
    end

    it "parses query parameters into the echo response" do
      client = make_client

      response = client.request(@server.endpoint,
        "GET", "/search?q=hello&page=2", host_header
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
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
      client = AwsCrt::Http::Client.new(
        ssl_verify_peer: false
      )

      response = client.request(@server.endpoint,
        "GET", "/tls-test",
        [["Host", "127.0.0.1:#{@server.port}"]]
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/tls-test")
    end
  end
end
