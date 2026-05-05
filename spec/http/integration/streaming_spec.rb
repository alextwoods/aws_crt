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
    @client = AwsCrt::Http::Client.new
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
      response = @client.request(@server.endpoint, "GET", "/small", [host_header]) do |chunk|
        chunks << chunk
      end

      expect(response.status_code).to eq(200)
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
      response = @client.request(@server.endpoint,
        "GET", "/large?body_size=#{body_size}", [host_header]
      ) do |chunk|
        chunks << chunk
      end

      expect(response.status_code).to eq(200)
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
      buffered_response = @client.request(@server.endpoint, "GET", path, [host_header])

      # Streamed
      chunks = []
      @client.request(@server.endpoint, "GET", path, [host_header]) do |chunk|
        chunks << chunk
      end
      streamed_body = chunks.join

      expect(streamed_body).to eq(buffered_response.body)
    end
  end

  describe "block streaming returns HttpResponse" do
    it "returns an HttpResponse with nil body" do
      response = @client.request(@server.endpoint, "GET", "/test", [host_header]) do |_chunk|
        # consume
      end

      expect(response).to be_a(AwsCrt::Http::Response)
      expect(response.status_code).to eq(200)
      expect(response.headers).to be_a(Hash)
      expect(response.body).to be_nil
    end
  end
end
