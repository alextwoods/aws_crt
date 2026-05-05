# frozen_string_literal: true

# Integration tests for the streaming_io feature of the CRT HTTP client.
#
# Tests that `streaming_io: true` returns a SharableStringIO with the
# correct response body content, that combining streaming_io with a block
# raises ArgumentError, and that existing (non-streaming_io) behavior
# remains unchanged.

require "json"
require "support/test_server"

RSpec.describe "streaming_io integration" do
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

  describe "streaming_io: true returns a SharableStringIO" do
    it "returns a SharableStringIO as the third element" do
      status, headers, body_io = @client.request(
        @server.endpoint, "GET", "/test", [host_header], streaming_io: true
      )

      expect(status).to eq(200)
      expect(headers).to be_an(Array)
      expect(body_io).to be_a(AwsCrt::Http::SharableStringIO)
    end

    it "contains the correct response body for a small response" do
      status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/small", [host_header], streaming_io: true
      )

      expect(status).to eq(200)
      body = body_io.read
      echo = JSON.parse(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/small")
    end

    it "contains the correct response body for an empty-body response" do
      # HEAD requests return no body
      status, _headers, body_io = @client.request(
        @server.endpoint, "HEAD", "/empty", [host_header], streaming_io: true
      )

      expect(status).to eq(200)
      expect(body_io.read).to eq("")
      expect(body_io.size).to eq(0)
    end

    it "contains the correct response body for a larger response (64KB)" do
      body_size = 64 * 1024
      status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/large?body_size=#{body_size}", [host_header],
        streaming_io: true
      )

      expect(status).to eq(200)
      content = body_io.read
      expect(content.bytesize).to eq(body_size)
      expect(content).to eq("x" * body_size)
    end

    it "returns a SharableStringIO that supports read, rewind, and size" do
      _status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/test", [host_header], streaming_io: true
      )

      # Read partial, then rewind and read all
      first_chunk = body_io.read(5)
      expect(first_chunk.bytesize).to eq(5)

      body_io.rewind
      full_body = body_io.read
      expect(full_body).to start_with(first_chunk)
      expect(body_io.size).to eq(full_body.bytesize)
    end

    it "returns a frozen, Ractor-shareable SharableStringIO" do
      _status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/test", [host_header], streaming_io: true
      )

      expect(body_io).to be_frozen
      expect(Ractor.shareable?(body_io)).to be true
    end

    it "returns ASCII-8BIT encoded content" do
      _status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/test", [host_header], streaming_io: true
      )

      content = body_io.read
      expect(content.encoding).to eq(Encoding::ASCII_8BIT)
    end
  end

  describe "streaming_io: true with a block raises ArgumentError" do
    it "raises ArgumentError with the correct message" do
      expect {
        @client.request(
          @server.endpoint, "GET", "/test", [host_header], streaming_io: true
        ) { |_chunk| }
      }.to raise_error(ArgumentError, "streaming_io and block are mutually exclusive")
    end
  end

  describe "Ractor integration with streaming_io" do
    it "creates a SharableStringIO in a Ractor and reads it in the main Ractor" do
      client = AwsCrt::Http::Client.new
      client.freeze
      endpoint = @server.endpoint
      port = @server.port

      # Run the HTTP request inside a Ractor, get back the SharableStringIO
      sio = Ractor.new(client, endpoint, port) do |c, ep, p|
        _status, _headers, body_io = c.request(
          ep, "GET", "/ractor-test",
          [["Host", "127.0.0.1:#{p}"]],
          streaming_io: true
        )
        body_io
      end.value

      # Read the SharableStringIO here in the main Ractor
      expect(sio).to be_a(AwsCrt::Http::SharableStringIO)
      expect(sio).to be_frozen
      body = sio.read
      echo = JSON.parse(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/ractor-test")
    end
  end

  describe "backward compatibility (no streaming_io)" do
    it "returns a body string when streaming_io is not specified" do
      status, headers, body = @client.request(
        @server.endpoint, "GET", "/test", [host_header]
      )

      expect(status).to eq(200)
      expect(headers).to be_an(Array)
      expect(body).to be_a(String)
      echo = JSON.parse(body)
      expect(echo["method"]).to eq("GET")
      expect(echo["path"]).to eq("/test")
    end

    it "returns a body string when streaming_io: false" do
      status, _headers, body = @client.request(
        @server.endpoint, "GET", "/test", [host_header], streaming_io: false
      )

      expect(status).to eq(200)
      expect(body).to be_a(String)
      expect(body).not_to be_a(AwsCrt::Http::SharableStringIO)
    end

    it "yields chunks to a block when streaming without streaming_io" do
      chunks = []
      status, headers = @client.request(
        @server.endpoint, "GET", "/test", [host_header]
      ) { |chunk| chunks << chunk }

      expect(status).to eq(200)
      expect(headers).to be_an(Array)
      expect(chunks).not_to be_empty
      body = chunks.join
      echo = JSON.parse(body)
      expect(echo["method"]).to eq("GET")
    end

    it "streaming_io and buffered produce equivalent body content" do
      # Buffered (default)
      _status_b, _headers_b, buffered_body = @client.request(
        @server.endpoint, "GET", "/equiv?body_size=4096", [host_header]
      )

      # streaming_io
      _status_s, _headers_s, body_io = @client.request(
        @server.endpoint, "GET", "/equiv?body_size=4096", [host_header],
        streaming_io: true
      )

      expect(body_io.read).to eq(buffered_body)
    end
  end

  describe "on_data listeners" do
    it "calls on_data listeners with the body in buffered mode" do
      received = []
      listener = ->(chunk) { received << chunk }

      _status, _headers, body = @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        on_data: [listener]
      )

      expect(received.size).to eq(1)
      expect(received.first).to eq(body)
    end

    it "calls on_data listeners with the body in streaming_io mode" do
      received = []
      listener = ->(chunk) { received << chunk }

      _status, _headers, body_io = @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        streaming_io: true, on_data: [listener]
      )

      expect(received.size).to eq(1)
      expect(received.first).to eq(body_io.read)
    end

    it "calls multiple on_data listeners" do
      received_a = []
      received_b = []
      listener_a = ->(chunk) { received_a << chunk }
      listener_b = ->(chunk) { received_b << chunk }

      @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        on_data: [listener_a, listener_b]
      )

      expect(received_a).not_to be_empty
      expect(received_b).not_to be_empty
      expect(received_a).to eq(received_b)
    end

    it "calls on_data listeners per chunk in block streaming mode" do
      block_chunks = []
      listener_chunks = []
      listener = ->(chunk) { listener_chunks << chunk }

      @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        on_data: [listener]
      ) { |chunk| block_chunks << chunk }

      expect(listener_chunks).to eq(block_chunks)
    end

    it "does not call on_data for empty bodies" do
      received = []
      listener = ->(chunk) { received << chunk }

      @client.request(
        @server.endpoint, "HEAD", "/empty", [host_header],
        on_data: [listener]
      )

      expect(received).to be_empty
    end

    it "works with nil on_data (no-op)" do
      status, _headers, body = @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        on_data: nil
      )

      expect(status).to eq(200)
      expect(body).to be_a(String)
    end

    it "works with empty on_data array (no-op)" do
      status, _headers, body = @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        on_data: []
      )

      expect(status).to eq(200)
      expect(body).to be_a(String)
    end
  end
end
