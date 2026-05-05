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
      @client = AwsCrt::Http::Client.new(
        ssl_verify_peer: false
      )
    end

    it "completes a GET request over HTTPS" do
      response = @client.request(@server.endpoint, "GET", "/tls-test", [host_header])

      expect(response.status_code).to eq(200)
      echo = parse_echo(response.body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/tls-test")
    end

    it "sends and receives a POST body over HTTPS" do
      request_body = "secure payload"
      request_headers = [
        host_header,
        ["Content-Length", request_body.bytesize.to_s]
      ]

      response = @client.request(@server.endpoint, "POST", "/secure", request_headers, request_body)

      expect(response.status_code).to eq(200)
      echo = parse_echo(response.body)
      expect(echo["method"]).to eq("POST")
      expect(echo["body"]).to eq("secure payload")
    end

    it "returns correct response headers over HTTPS" do
      response = @client.request(@server.endpoint, "GET", "/", [host_header])

      header_hash = response.headers.transform_keys(&:downcase)
      expect(header_hash["content-type"]).to eq("application/json")
      expect(header_hash).to have_key("content-length")
    end
  end

  describe "TLS handshake failure" do
    it "raises an error when connecting to a self-signed cert with verification enabled" do
      client = AwsCrt::Http::Client.new(
        ssl_verify_peer: true
      )

      expect {
        client.request(@server.endpoint, "GET", "/should-fail", [host_header])
      }.to raise_error(AwsCrt::Http::Error)
    end
  end
end
