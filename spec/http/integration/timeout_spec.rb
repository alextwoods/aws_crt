# frozen_string_literal: true

# Integration tests for timeout behavior through the CRT client.
#
# Tests connect timeout with non-routable addresses, read timeout with
# delayed server responses, and default timeout values.
#
# Requirements: 6.1, 6.2, 6.3, 6.4, 12.2

require "json"
require "support/test_server"

RSpec.describe "Timeout integration" do
  before(:all) do
    @server = TestServer.start
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

  describe "read timeout" do
    before(:all) do
      @timeout_pool = AwsCrt::Http::ConnectionPool.new(
        @server.endpoint,
        read_timeout_ms: 1_000
      )
    end

    it "raises an error when the server response is delayed beyond the read timeout" do
      # Server delays 5 seconds, but our read timeout is 1 second
      expect {
        @timeout_pool.request("GET", "/slow?delay=5", [host_header])
      }.to raise_error(AwsCrt::Http::Error)
    end

    it "succeeds when the server responds within the read timeout" do
      # No delay — should complete well within 1 second
      status, _headers, body = @timeout_pool.request("GET", "/fast", [host_header])

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/fast")
    end
  end

  describe "connect timeout" do
    it "raises an error when connecting to a non-routable address" do
      # 192.0.2.1 is TEST-NET-1 (RFC 5737), guaranteed non-routable.
      # Use a very short timeout to avoid slow tests.
      pool = AwsCrt::Http::ConnectionPool.new(
        "http://192.0.2.1:80",
        connect_timeout_ms: 500
      )

      expect {
        pool.request("GET", "/", [["Host", "192.0.2.1"]])
      }.to raise_error(AwsCrt::Http::Error)
    end
  end

  describe "default timeouts" do
    it "completes a normal request with default timeout configuration" do
      # A pool with no explicit timeout config should use reasonable defaults
      # and complete normal requests without issue.
      pool = AwsCrt::Http::ConnectionPool.new(@server.endpoint)

      status, _headers, body = pool.request("GET", "/defaults", [host_header])

      expect(status).to eq(200)
      echo = parse_echo(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/defaults")
    end
  end
end
