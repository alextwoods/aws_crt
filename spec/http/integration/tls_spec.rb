# frozen_string_literal: true

# Integration tests for TLS connections through the CRT client.
#
# On macOS, the CRT uses Security.framework for TLS, which does NOT
# honor custom CA bundles passed via the CRT API. These tests focus
# on behavior that works cross-platform:
#   - HTTPS with ssl_verify_peer disabled
#   - TLS handshake failure with verification enabled against self-signed certs
#   - Request/response correctness over HTTPS
#
# Requirements: 5.1, 5.2, 5.3, 5.5, 12.2

require "json"
require "support/test_server"

RSpec.describe "TLS integration" do
  before(:all) do
    @server = TestServer.start(tls: true)
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

  describe "HTTPS with ssl_verify_peer disabled" do
    before(:all) do
      @pool = AwsCrt::Http::ConnectionPool.new(
        @server.endpoint,
        ssl_verify_peer: false
      )
    end

    it "completes a GET request over HTTPS" do
      status, _headers, body = @pool.request("GET", "/tls-test", [host_header])

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/tls-test")
    end

    it "sends and receives a POST body over HTTPS" do
      request_body = "secure payload"
      request_headers = [
        host_header,
        ["Content-Length", request_body.bytesize.to_s]
      ]

      status, _headers, body = @pool.request("POST", "/secure", request_headers, request_body)

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("POST")
      expect(echo["body"]).to eq("secure payload")
    end

    it "returns correct response headers over HTTPS" do
      _status, headers, _body = @pool.request("GET", "/", [host_header])

      header_hash = headers.to_h { |k, v| [k.downcase, v] }
      expect(header_hash["content-type"]).to eq("application/json")
      expect(header_hash).to have_key("content-length")
    end
  end

  describe "TLS handshake failure" do
    it "raises an error when connecting to a self-signed cert with verification enabled" do
      pool = AwsCrt::Http::ConnectionPool.new(
        @server.endpoint,
        ssl_verify_peer: true
      )

      expect {
        pool.request("GET", "/should-fail", [host_header])
      }.to raise_error(AwsCrt::Http::Error)
    end
  end
end
