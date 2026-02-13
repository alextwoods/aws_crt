# frozen_string_literal: true

# Integration tests for basic HTTP requests through the CRT client.
#
# Tests GET, POST, PUT, DELETE, PATCH, HEAD methods with and without
# bodies, verifying response status code, headers, and body correctness.
#
# Requirements: 4.1, 4.6, 12.2

require "json"
require "support/test_server"

RSpec.describe "Basic HTTP request integration" do
  before(:all) do
    @server = TestServer.start
    @pool = AwsCrt::Http::ConnectionPool.new(@server.endpoint)
  end

  after(:all) do
    @server&.stop
  end

  def host_header
    ["Host", "127.0.0.1:#{@server.port}"]
  end

  def parse_echo(body)
    JSON.parse(body)
  end

  def headers_hash(headers)
    headers.to_h.transform_keys(&:downcase)
  end

  describe "HTTP methods" do
    it "sends a GET request and receives the echo response" do
      status, _headers, body = @pool.request("GET", "/test", [host_header])

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/test")
      expect(echo["body"]).to eq("")
    end

    it "sends a POST request with a body" do
      request_body = "hello world"
      request_headers = [
        host_header,
        ["Content-Length", request_body.bytesize.to_s]
      ]

      status, _headers, body = @pool.request("POST", "/submit", request_headers, request_body)

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/submit")
      expect(echo["body"]).to eq("hello world")
    end

    it "sends a PUT request with a body" do
      request_body = '{"key":"value"}'
      request_headers = [
        host_header,
        ["Content-Type", "application/json"],
        ["Content-Length", request_body.bytesize.to_s]
      ]

      status, _headers, body = @pool.request("PUT", "/resource/1", request_headers, request_body)

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("PUT")
      expect(echo["path"]).to eq("/resource/1")
      expect(echo["body"]).to eq('{"key":"value"}')
    end

    it "sends a DELETE request without a body" do
      status, _headers, body = @pool.request("DELETE", "/resource/1", [host_header])

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("DELETE")
      expect(echo["path"]).to eq("/resource/1")
      expect(echo["body"]).to eq("")
    end

    it "sends a DELETE request with a body" do
      request_body = '{"id":42}'
      request_headers = [
        host_header,
        ["Content-Length", request_body.bytesize.to_s]
      ]

      status, _headers, body = @pool.request("DELETE", "/resource/1", request_headers, request_body)

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("DELETE")
      expect(echo["body"]).to eq('{"id":42}')
    end

    it "sends a PATCH request with a body" do
      request_body = '{"name":"updated"}'
      request_headers = [
        host_header,
        ["Content-Type", "application/json"],
        ["Content-Length", request_body.bytesize.to_s]
      ]

      status, _headers, body = @pool.request("PATCH", "/resource/1", request_headers, request_body)

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("PATCH")
      expect(echo["path"]).to eq("/resource/1")
      expect(echo["body"]).to eq('{"name":"updated"}')
    end

    it "sends a HEAD request and receives no body" do
      status, headers, body = @pool.request("HEAD", "/info", [host_header])

      expect(status).to eq(200)
      expect(body).to eq("")
      # HEAD responses still include headers
      header_hash = headers_hash(headers)
      expect(header_hash).to have_key("content-type")
    end
  end

  describe "requests without bodies" do
    %w[GET DELETE HEAD].each do |method|
      it "#{method} without a body succeeds" do
        status, _headers, body = @pool.request(method, "/no-body", [host_header])

        expect(status).to eq(200)
        next if method == "HEAD" # HEAD has no response body to parse

        echo = parse_echo(body)
        expect(echo["method"]).to eq(method)
        expect(echo["body"]).to eq("")
      end
    end
  end

  describe "requests with bodies" do
    %w[POST PUT PATCH DELETE].each do |method|
      it "#{method} with a body round-trips the content" do
        request_body = "body for #{method}"
        request_headers = [
          host_header,
          ["Content-Length", request_body.bytesize.to_s]
        ]

        status, _headers, body = @pool.request(method, "/with-body", request_headers, request_body)

        expect(status).to eq(200)
        echo = parse_echo(body)
        expect(echo["method"]).to eq(method)
        expect(echo["body"]).to eq(request_body)
      end
    end
  end

  describe "response status code" do
    it "returns 200 for a successful request" do
      status, _headers, _body = @pool.request("GET", "/", [host_header])
      expect(status).to eq(200)
    end
  end

  describe "response headers" do
    it "returns response headers as name-value pairs" do
      _status, headers, _body = @pool.request("GET", "/", [host_header])

      expect(headers).to be_an(Array)
      expect(headers).to all(be_an(Array).and(have_attributes(size: 2)))
    end

    it "includes Content-Type in the response" do
      _status, headers, _body = @pool.request("GET", "/", [host_header])

      header_hash = headers_hash(headers)
      expect(header_hash["content-type"]).to eq("application/json")
    end

    it "includes Content-Length in the response" do
      _status, headers, body = @pool.request("GET", "/", [host_header])

      header_hash = headers_hash(headers)
      expect(header_hash["content-length"]).to eq(body.bytesize.to_s)
    end
  end

  describe "response body" do
    it "returns the complete response body as a string" do
      _status, _headers, body = @pool.request("GET", "/", [host_header])

      expect(body).to be_a(String)
      echo = parse_echo(body)
      expect(echo).to be_a(Hash)
      expect(echo).to have_key("method")
    end

    it "returns an empty body for HEAD requests" do
      _status, _headers, body = @pool.request("HEAD", "/", [host_header])
      expect(body).to eq("")
    end
  end

  describe "request headers are echoed" do
    it "sends custom headers that appear in the echo response" do
      request_headers = [
        host_header,
        %w[X-Custom-Header custom-value],
        %w[X-Another another-value]
      ]

      _status, _headers, body = @pool.request("GET", "/headers", request_headers)

      echo = parse_echo(body)
      expect(echo["headers"]["X-Custom-Header"]).to eq("custom-value")
      expect(echo["headers"]["X-Another"]).to eq("another-value")
    end
  end

  describe "request paths" do
    it "handles a root path" do
      _status, _headers, body = @pool.request("GET", "/", [host_header])
      echo = parse_echo(body)
      expect(echo["path"]).to eq("/")
    end

    it "handles nested paths" do
      _status, _headers, body = @pool.request("GET", "/a/b/c/d", [host_header])
      echo = parse_echo(body)
      expect(echo["path"]).to eq("/a/b/c/d")
    end

    it "handles paths with query strings" do
      _status, _headers, body = @pool.request("GET", "/search?q=test&page=1", [host_header])
      echo = parse_echo(body)
      expect(echo["path"]).to eq("/search")
      expect(echo["query"]).to include("q" => "test", "page" => "1")
    end
  end
end
