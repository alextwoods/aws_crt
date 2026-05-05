# frozen_string_literal: true

# Unit tests for AwsCrt::Http::Handler.
#
# Requirements:
#   8.1 — Handler implements call(context) reading http_request / writing http_response
#   8.2 — Translates Seahorse request (endpoint, method, headers, body) to CRT request
#   8.3 — Populates http_response with status_code, headers, body from CRT response
#   8.4 — Streams response body via signal_data when response_target is set
#   8.6 — Wraps CRT errors in Seahorse::Client::NetworkingError

require "socket"
require "json"
require "uri"
require "stringio"
require "logger"

# Minimal Seahorse stubs
module Seahorse
  module Client
    class Handler
      attr_accessor :handler

      def initialize(handler = nil)
        @handler = handler
      end
    end

    class Response
      attr_accessor :context

      def initialize(context: nil)
        @context = context
      end
    end

    class NetworkingError < StandardError
      attr_reader :original_error

      def initialize(error, message = nil)
        @original_error = error
        super(message || error.message)
      end
    end
  end
end

require_relative "../../lib/aws_crt/http/handler"

# JSON echo server
module HandlerEchoServer
  def self.start
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { accept_loop(server) }
    [server, thread, port]
  end

  def self.accept_loop(server)
    loop do
      client = server.accept
      handle(client)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # Client disconnected
    end
  end

  def self.handle(client)
    request_line = client.gets
    return unless request_line

    method, path, = request_line.strip.split(" ", 3)

    headers = {}
    content_length = 0
    while (line = client.gets) && line.strip != ""
      name, value = line.split(":", 2)
      next unless name && value

      name = name.strip
      value = value.strip
      headers[name] = value
      content_length = value.to_i if name.casecmp("Content-Length").zero?
    end

    body = content_length.positive? ? client.read(content_length) : ""

    echo = JSON.generate(
      "method" => method, "path" => path,
      "headers" => headers, "body" => body
    )

    resp = "HTTP/1.1 200 OK\r\n" \
           "Content-Type: application/json\r\n" \
           "X-Echo: true\r\n" \
           "Content-Length: #{echo.bytesize}\r\n" \
           "Connection: close\r\n\r\n"
    client.write(resp)
    client.write(echo) unless method == "HEAD"
  ensure
    client&.close
  end
end

# Lightweight Seahorse stand-ins
module HandlerStubs
  Headers = Struct.new(:pairs) do
    def each_pair(&block)
      pairs.each { |name, value| block.call(name, value) }
    end
  end

  Request = Struct.new(:endpoint, :http_method, :headers, :body)

  class Response
    attr_accessor :status_code, :headers, :body_chunks, :done, :error

    def initialize
      @headers = {}
      @body_chunks = []
      @done = false
      @error = nil
    end

    def signal_headers(status, hdrs)
      @status_code = status
      hdrs.each { |k, v| @headers[k] = v }
    end

    def signal_data(data)
      @body_chunks << data
    end

    def signal_done
      @done = true
    end

    def signal_error(err)
      @error = err
    end

    def body_string
      @body_chunks.join
    end
  end

  Config = Struct.new(:crt_http_client, :logger, keyword_init: true)

  class Context
    attr_accessor :http_request, :http_response, :config, :metadata

    def initialize(http_request:, http_response:, config:, metadata: {})
      @http_request = http_request
      @http_response = http_response
      @config = config
      @metadata = metadata
    end

    def [](key)
      @metadata[key]
    end
  end
end

RSpec.describe AwsCrt::Http::Handler do
  around do |example|
    server, thread, port = HandlerEchoServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  def make_client
    AwsCrt::Http::Client.new
  end

  def build_context(method:, path:, headers: [], body: nil, streaming: false, logger: nil)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    stub_headers = HandlerStubs::Headers.new(
      [["Host", "127.0.0.1:#{@port}"]] + headers
    )

    request = HandlerStubs::Request.new(uri, method, stub_headers, body)
    response = HandlerStubs::Response.new
    config = HandlerStubs::Config.new(
      crt_http_client: make_client,
      logger: logger
    )
    metadata = streaming ? { response_target: proc {} } : {}
    HandlerStubs::Context.new(
      http_request: request,
      http_response: response,
      config: config,
      metadata: metadata
    )
  end

  describe "Seahorse request → CRT request translation" do
    it "translates method, path, headers, and body to the CRT request" do
      body = "hello from handler test"
      context = build_context(
        method: "POST",
        path: "/test/translate",
        headers: [
          ["Content-Length", body.bytesize.to_s],
          ["X-Custom", "custom-value"]
        ],
        body: StringIO.new(body)
      )

      handler = described_class.new
      result = handler.call(context)

      expect(result).to be_a(Seahorse::Client::Response)
      expect(context.http_response.status_code).to eq(200)

      echo = JSON.parse(context.http_response.body_string)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/test/translate")
      expect(echo["headers"]["X-Custom"]).to eq("custom-value")
      expect(echo["body"]).to eq(body)
    end

    it "handles GET requests with no body" do
      context = build_context(method: "GET", path: "/no-body")

      handler = described_class.new
      handler.call(context)

      resp = context.http_response
      expect(resp.status_code).to eq(200),
        "status_code was nil; error=#{resp.error.inspect}; body_chunks=#{resp.body_chunks.size}"
    end

    it "reads body from an IO-like object and rewinds it" do
      body_io = StringIO.new("io body content")
      context = build_context(
        method: "PUT",
        path: "/io-body",
        headers: [["Content-Length", "15"]],
        body: body_io
      )

      handler = described_class.new
      handler.call(context)

      echo = JSON.parse(context.http_response.body_string)
      expect(echo["body"]).to eq("io body content")
      expect(body_io.pos).to eq(0)
    end
  end

  describe "CRT response → Seahorse response population" do
    it "populates status_code, headers, and body on the Seahorse response" do
      body = "check"
      context = build_context(
        method: "POST",
        path: "/response-check",
        headers: [["Content-Length", body.bytesize.to_s]],
        body: StringIO.new(body)
      )

      handler = described_class.new
      handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_nil, "unexpected error: #{resp.error.inspect}"
      expect(resp.status_code).to eq(200)
      expect(resp.headers["Content-Type"]).to eq("application/json")
      expect(resp.headers["X-Echo"]).to eq("true")
      expect(resp.done).to be true
      expect(resp.body_string).not_to be_empty
    end
  end

  describe "error wrapping" do
    it "wraps AwsCrt::Http::Error in NetworkingError via signal_error" do
      context = build_context(method: "GET", path: "/will-fail")

      # Use a fake client that raises
      fake_client = Object.new
      def fake_client.request(*)
        raise AwsCrt::Http::Error, "CRT request failed"
      end
      context.config.crt_http_client = fake_client

      handler = described_class.new
      result = handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_a(Seahorse::Client::NetworkingError)
      expect(resp.error.original_error).to be_a(AwsCrt::Http::Error)
      expect(resp.error.message).to eq("CRT request failed")
      expect(result).to be_a(Seahorse::Client::Response)
    end

    it "wraps TimeoutError as NetworkingError" do
      context = build_context(method: "GET", path: "/timeout-test")

      fake_client = Object.new
      def fake_client.request(*)
        raise AwsCrt::Http::TimeoutError, "read timeout"
      end
      context.config.crt_http_client = fake_client

      handler = described_class.new
      handler.call(context)

      expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
      expect(context.http_response.error.original_error).to be_a(AwsCrt::Http::TimeoutError)
    end

    it "wraps ConnectionError as NetworkingError" do
      context = build_context(method: "GET", path: "/conn-error")

      fake_client = Object.new
      def fake_client.request(*)
        raise AwsCrt::Http::ConnectionError, "connection refused"
      end
      context.config.crt_http_client = fake_client

      handler = described_class.new
      handler.call(context)

      expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
      expect(context.http_response.error.original_error).to be_a(AwsCrt::Http::ConnectionError)
    end
  end

  describe "streaming path" do
    it "streams body chunks via signal_data when response_target is set" do
      body = "stream-body"
      context = build_context(
        method: "POST",
        path: "/stream-me",
        headers: [["Content-Length", body.bytesize.to_s]],
        body: StringIO.new(body),
        streaming: true
      )

      handler = described_class.new
      handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_nil, "unexpected error: #{resp.error.inspect}"
      expect(resp.status_code).to eq(200)
      expect(resp.done).to be true
      expect(resp.body_chunks).not_to be_empty
      echo = JSON.parse(resp.body_string)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/stream-me")
    end
  end

  describe "buffered path (streaming_io: true)" do
    it "uses streaming_io: true and delivers the response body correctly" do
      body = "buffered-body"
      context = build_context(
        method: "POST",
        path: "/buffered",
        headers: [["Content-Length", body.bytesize.to_s]],
        body: StringIO.new(body),
        streaming: false
      )

      handler = described_class.new
      handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_nil, "unexpected error: #{resp.error.inspect}"
      expect(resp.status_code).to eq(200)
      expect(resp.done).to be true
      expect(resp.body_chunks.size).to eq(1)
      echo = JSON.parse(resp.body_string)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/buffered")
    end

    it "passes streaming_io: true to the CRT client request" do
      context = build_context(
        method: "GET",
        path: "/streaming-io-check",
        streaming: false
      )

      # Use a spy client that records the keyword arguments
      received_kwargs = nil
      # Create a real response via the echo server
      real_client = make_client
      real_response = real_client.request(
        "http://127.0.0.1:#{@port}", "GET", "/spy-setup",
        [["Host", "127.0.0.1:#{@port}"]],
        streaming_io: true
      )

      spy_client = Object.new
      spy_client.define_singleton_method(:request) do |*args, **kwargs|
        received_kwargs = kwargs
        real_response
      end
      context.config.crt_http_client = spy_client

      handler = described_class.new
      handler.call(context)

      expect(received_kwargs).to eq({ streaming_io: true })
    end

    it "reads from the SharableStringIO and passes string data to signal_data" do
      body = "sdk-read-test"
      context = build_context(
        method: "POST",
        path: "/sdk-read",
        headers: [["Content-Length", body.bytesize.to_s]],
        body: StringIO.new(body),
        streaming: false
      )

      # Capture the actual body data passed to signal_data
      captured_data = nil
      resp = context.http_response
      original_signal_data = resp.method(:signal_data)
      resp.define_singleton_method(:signal_data) do |data|
        captured_data = data
        original_signal_data.call(data)
      end

      handler = described_class.new
      handler.call(context)

      expect(resp.error).to be_nil, "unexpected error: #{resp.error.inspect}"
      # The data passed to signal_data is a String (read from SharableStringIO)
      expect(captured_data).to be_a(String)
      expect(captured_data.encoding).to eq(Encoding::ASCII_8BIT)

      echo = JSON.parse(captured_data)
      expect(echo["body"]).to eq("sdk-read-test")
    end

    it "does not call signal_data for empty response body" do
      # Use HEAD which returns no body from our echo server
      context = build_context(
        method: "HEAD",
        path: "/empty-body",
        streaming: false
      )

      handler = described_class.new
      handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_nil, "unexpected error: #{resp.error.inspect}"
      expect(resp.status_code).to eq(200)
      expect(resp.done).to be true
      # No signal_data should be called for empty body
      expect(resp.body_chunks).to be_empty
    end

    it "SharableStringIO response body supports the SDK read interface" do
      # Verify that the SharableStringIO returned by the CRT client
      # supports the interface the SDK expects for response bodies
      body_content = "hello from CRT"
      client = make_client
      response = client.request(
        "http://127.0.0.1:#{@port}", "POST", "/sio-interface-test",
        [["Host", "127.0.0.1:#{@port}"], ["Content-Length", body_content.bytesize.to_s]],
        body_content,
        streaming_io: true
      )
      sio = response.body

      # The SharableStringIO contains the echo server's JSON response
      full_body = sio.read
      expect(full_body).not_to be_empty

      # SDK reads the full body
      sio.rewind
      expect(sio.read).to eq(full_body)

      # SDK rewinds and reads again
      sio.rewind
      expect(sio.read).to eq(full_body)

      # SDK reads in chunks
      sio.rewind
      chunk = sio.read(5)
      expect(chunk.bytesize).to eq(5)
      expect(chunk.encoding).to eq(Encoding::ASCII_8BIT)

      # SDK checks size
      expect(sio.size).to eq(full_body.bytesize)

      # SDK checks eof
      sio.rewind
      expect(sio.eof?).to be false
      sio.read
      expect(sio.eof?).to be true
    end
  end

  describe "always returns Seahorse::Client::Response" do
    it "returns a Response even on success" do
      context = build_context(method: "GET", path: "/ok")
      result = described_class.new.call(context)
      expect(result).to be_a(Seahorse::Client::Response)
      expect(result.context).to equal(context)
    end

    it "returns a Response even on error" do
      context = build_context(method: "GET", path: "/err")

      fake_client = Object.new
      def fake_client.request(*)
        raise AwsCrt::Http::Error, "boom"
      end
      context.config.crt_http_client = fake_client

      result = described_class.new.call(context)
      expect(result).to be_a(Seahorse::Client::Response)
      expect(result.context).to equal(context)
    end
  end
end
