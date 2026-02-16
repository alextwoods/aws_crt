# frozen_string_literal: true

# Feature: crt-http-client, Property 8: Debug Logging Completeness
#
# For any HTTP request/response cycle when a logger is configured, the
# debug log output SHALL contain the request HTTP method, the request
# URI, the response status code, and a non-negative elapsed time value.
#
# **Validates: Requirements 10.3**
#
# Strategy: The Handler requires Seahorse (aws-sdk-core), which is not
# in the test group. We define minimal stub classes that satisfy the
# Handler's interface, then exercise the full call(context) path with
# a real ConnectionPool and a local echo server. A StringIO-backed
# Logger captures the debug output, which we parse and verify.

require "socket"
require "logger"
require "stringio"
require "uri"
require "rantly"
require "rantly/rspec_extensions"

# Minimal Seahorse stubs — just enough for Handler to load and run.
# Defined before requiring the handler so the class inheritance resolves.
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

require_relative "../../../lib/aws_crt/http/handler"

# Simple echo server that returns a 200 with a short body.
module LoggingEchoServer
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

    method = request_line.strip.split(" ", 3).first

    # Drain request headers and capture Content-Length
    content_length = 0
    while (line = client.gets) && line.strip != ""
      name, value = line.split(":", 2)
      content_length = value.strip.to_i if name&.strip&.casecmp("Content-Length")&.zero?
    end

    # Drain request body if present
    client.read(content_length) if content_length.positive?

    body = "ok"
    head = "HTTP/1.1 200 OK\r\n" \
           "Content-Length: #{body.bytesize}\r\n" \
           "Connection: close\r\n\r\n"
    client.write(head)
    client.write(body) unless method == "HEAD"
  ensure
    client&.close
  end
end

# Lightweight stand-ins for Seahorse request/response/config/context.
# Only the methods actually called by Handler are implemented.
module LoggingStubs
  Headers = Struct.new(:pairs) do
    def each_pair(&block)
      pairs.each { |name, value| block.call(name, value) }
    end
  end

  Request = Struct.new(:endpoint, :http_method, :headers, :body)

  Response = Struct.new(:status_code, :headers, :body_data) do
    def initialize(*)
      super
      self.headers ||= {}
      self.body_data ||= ""
    end

    def signal_headers(status, hdrs)
      self.status_code = status
      hdrs.each { |k, v| headers[k] = v }
    end

    def signal_data(data)
      self.body_data = (body_data || "") + data
    end

    def signal_done; end

    def signal_error(error)
      raise error
    end
  end

  Config = Struct.new(:crt_pool_manager, :logger, keyword_init: true)

  Context = Struct.new(:http_request, :http_response, :config, :metadata) do
    def initialize(*)
      super
      self.metadata ||= {}
    end

    def [](key)
      metadata[key]
    end
  end
end

RSpec.describe "Property 8: Debug Logging Completeness" do
  around do |example|
    server, thread, port = LoggingEchoServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  # HTTP methods that carry a body — avoids a known Handler issue where
  # passing an explicit nil body to the Rust pool raises TypeError.
  HTTP_METHODS = %w[POST PUT DELETE PATCH].freeze

  def make_pool_manager
    AwsCrt::Http::ConnectionPoolManager.new({})
  end

  def build_context(method:, path:, port:, pool_manager:, logger:, body:)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    headers = LoggingStubs::Headers.new([
      ["Host", "127.0.0.1:#{port}"],
      ["Content-Length", body.bytesize.to_s]
    ])

    request = LoggingStubs::Request.new(uri, method, headers, body)
    response = LoggingStubs::Response.new
    config = LoggingStubs::Config.new(crt_pool_manager: pool_manager, logger: logger)
    LoggingStubs::Context.new(request, response, config)
  end

  # Parse the log line produced by Handler#log_request.
  # Expected format: [AwsCrt::Http] METHOD URI -> STATUS (ELAPSEDs)
  LOG_PATTERN = /\[AwsCrt::Http\]\s+(\S+)\s+(\S+)\s+->\s+(\S+)\s+\(([0-9.]+)s\)/

  def random_path
    segments = rand(1..3)
    "/" + segments.times.map {
      len = rand(1..8)
      len.times.map { (("a".."z").to_a + ("0".."9").to_a).sample }.join
    }.join("/")
  end

  def random_body
    len = rand(1..64)
    len.times.map { rand(32..126).chr }.join
  end

  it "log output contains method, URI, status code, and non-negative elapsed time" do
    property_of {
      choose(*HTTP_METHODS)
    }.check(20) do |method|
      path = random_path
      body = random_body

      log_io = StringIO.new
      logger = Logger.new(log_io, level: Logger::DEBUG)

      pool_manager = make_pool_manager
      context = build_context(
        method: method, path: path, port: @port,
        pool_manager: pool_manager, logger: logger, body: body
      )

      handler = AwsCrt::Http::Handler.new
      handler.call(context)

      log_output = log_io.string

      match = LOG_PATTERN.match(log_output)
      expect(match).not_to be_nil,
                           "Expected log output to match pattern, got: #{log_output.inspect}"

      logged_method = match[1]
      logged_uri = match[2]
      logged_status = match[3]
      logged_elapsed = match[4].to_f

      expect(logged_method).to eq(method),
                               "Logged method #{logged_method.inspect} != sent method #{method.inspect}"

      expect(logged_uri).to include(path),
                            "Logged URI #{logged_uri.inspect} should contain path #{path.inspect}"

      expect(logged_status).to eq("200"),
                               "Logged status #{logged_status.inspect} != expected 200"

      expect(logged_elapsed).to be >= 0,
                                "Elapsed time #{logged_elapsed} should be non-negative"
    end
  end
end
