# frozen_string_literal: true

# Integration tests for streaming responses through the CRT client.
#
# Tests streaming with small and large response bodies, verifies that
# chunks are yielded incrementally for large responses, and confirms
# streaming vs buffered equivalence.
#
# Requirements: 4.7, 8.4, 12.2

require "json"
require "support/test_server"

RSpec.describe "Streaming response integration" do
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

  describe "small body streaming" do
    it "yields the complete body via streaming block" do
      chunks = []
      status, _headers = @pool.request("GET", "/small", [host_header]) do |chunk|
        chunks << chunk
      end

      expect(status).to eq(200)
      body = chunks.join
      echo = JSON.parse(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/small")
    end
  end

  describe "large body streaming" do
    it "yields the full body in multiple chunks for a 128KB response" do
      body_size = 128 * 1024
      chunks = []
      status, _headers = @pool.request(
        "GET", "/large?body_size=#{body_size}", [host_header]
      ) do |chunk|
        chunks << chunk
      end

      expect(status).to eq(200)
      full_body = chunks.join
      expect(full_body.bytesize).to eq(body_size)
      expect(full_body).to eq("x" * body_size)
      expect(chunks.size).to be > 1,
        "Expected multiple chunks for a #{body_size}-byte response, got #{chunks.size}"
    end
  end

  describe "streaming vs buffered equivalence" do
    it "produces the same body whether streamed or buffered" do
      path = "/equiv?body_size=4096"

      # Buffered
      _status_b, _headers_b, buffered_body = @pool.request("GET", path, [host_header])

      # Streamed
      chunks = []
      _status_s, _headers_s = @pool.request("GET", path, [host_header]) do |chunk|
        chunks << chunk
      end
      streamed_body = chunks.join

      expect(streamed_body).to eq(buffered_body)
    end
  end
end
