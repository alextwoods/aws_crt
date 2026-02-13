# frozen_string_literal: true

# Unit tests for AwsCrt::Http::Handler.
#
# Requirements:
#   8.1 — Handler implements call(context) reading http_request / writing http_response
#   8.2 — Translates Seahorse request (endpoint, method, headers, body) to CRT request
#   8.3 — Populates http_response with status_code, headers, body from CRT response
#   8.4 — Streams response body via signal_data when response_target is set
#   8.6 — Wraps CRT errors in Seahorse::Client::NetworkingError
#  12.1 — Unit tests for Handler

require "socket"
require "json"
require "uri"
require "stringio"
require "logger"

# Minimal Seahorse stubs — just enough for Handler to load and run.
# Matches the pattern established in spec/http/properties/logging_spec.rb.
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

# JSON echo server that reflects the request back as a structured response.
# Returns method, path, headers, and body so tests can verify the translation.
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
      # Client disconnected — continue accepting
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

# Lightweight Seahorse stand-ins. Only the methods actually called by
# Handler are implemented.
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

  Config = Struct.new(:crt_pool_manager, :logger, keyword_init: true)

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

  def make_pool_manager
    AwsCrt::Http::ConnectionPoolManager.new({})
  end

  def build_context(method:, path:, headers: [], body: nil, streaming: false, logger: nil)
    uri = URI("http://127.0.0.1:#{@port}#{path}")
    stub_headers = HandlerStubs::Headers.new(
      [["Host", "127.0.0.1:#{@port}"]] + headers
    )

    request = HandlerStubs::Request.new(uri, method, stub_headers, body)
    response = HandlerStubs::Response.new
    config = HandlerStubs::Config.new(
      crt_pool_manager: make_pool_manager,
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
      # Handler should rewind the body after reading
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

      # Use a fake pool that raises a generic AwsCrt::Http::Error
      fake_pool = Object.new
      def fake_pool.request(*)
        raise AwsCrt::Http::Error, "CRT request failed"
      end

      fake_manager = Object.new
      fake_manager.define_singleton_method(:pool_for) { |_| fake_pool }
      context.config.crt_pool_manager = fake_manager

      handler = described_class.new
      result = handler.call(context)

      resp = context.http_response
      expect(resp.error).to be_a(Seahorse::Client::NetworkingError)
      expect(resp.error.original_error).to be_a(AwsCrt::Http::Error)
      expect(resp.error.message).to eq("CRT request failed")
      # Should still return a Seahorse::Client::Response
      expect(result).to be_a(Seahorse::Client::Response)
    end

    it "wraps TimeoutError as NetworkingError" do
      context = build_context(method: "GET", path: "/timeout-test")

      # Simulate a TimeoutError by using a pool that raises one.
      # We create a real pool manager but intercept pool_for to return
      # a pool whose request method raises TimeoutError.
      fake_pool = Object.new
      def fake_pool.request(*)
        raise AwsCrt::Http::TimeoutError, "read timeout"
      end

      fake_manager = Object.new
      fake_manager.define_singleton_method(:pool_for) { |_| fake_pool }
      context.config.crt_pool_manager = fake_manager

      handler = described_class.new
      handler.call(context)

      expect(context.http_response.error).to be_a(Seahorse::Client::NetworkingError)
      expect(context.http_response.error.original_error).to be_a(AwsCrt::Http::TimeoutError)
    end

    it "wraps ConnectionError as NetworkingError" do
      context = build_context(method: "GET", path: "/conn-error")

      fake_pool = Object.new
      def fake_pool.request(*)
        raise AwsCrt::Http::ConnectionError, "connection refused"
      end

      fake_manager = Object.new
      fake_manager.define_singleton_method(:pool_for) { |_| fake_pool }
      context.config.crt_pool_manager = fake_manager

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
      # In streaming mode, body arrives as one or more chunks via signal_data
      expect(resp.body_chunks).not_to be_empty
      # The concatenated chunks should form valid JSON (the echo response)
      echo = JSON.parse(resp.body_string)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/stream-me")
    end
  end

  describe "buffered path" do
    it "buffers the full body and writes it at once when no response_target" do
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
      # In buffered mode, body is written via a single signal_data call
      expect(resp.body_chunks.size).to eq(1)
      echo = JSON.parse(resp.body_chunks.first)
      expect(echo["method"]).to eq("POST")
      expect(echo["path"]).to eq("/buffered")
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

      fake_pool = Object.new
      def fake_pool.request(*)
        raise AwsCrt::Http::Error, "boom"
      end

      fake_manager = Object.new
      fake_manager.define_singleton_method(:pool_for) { |_| fake_pool }
      context.config.crt_pool_manager = fake_manager

      result = described_class.new.call(context)
      expect(result).to be_a(Seahorse::Client::Response)
      expect(result.context).to equal(context)
    end
  end
end
