# frozen_string_literal: true

# Feature: crt-http-client, Property 4: Streaming Body Integrity
#
# For any HTTP response body, when received via the streaming interface,
# the concatenation of all yielded chunks SHALL be byte-identical to the
# complete response body received via the non-streaming interface for the
# same request.
#
# **Validates: Requirements 4.7, 8.4**

require "socket"
require "rantly"
require "rantly/rspec_extensions"

# TCP server that returns a response with a caller-specified body.
# The test sets `next_response_body` before each request. The server
# is stateless per-connection and uses Connection: close so each
# request gets a fresh TCP connection (avoiding keep-alive ambiguity).
module StreamingBodyServer
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

    # Drain request headers
    nil while (line = client.gets) && line.strip != ""

    write_response(client)
  ensure
    client&.close
  end

  def self.write_response(client)
    body = @next_response_body || ""

    head = "HTTP/1.1 200 OK\r\n" \
           "Content-Length: #{body.bytesize}\r\n" \
           "Connection: close\r\n\r\n"

    client.write(head)
    client.write(body)
  end

  def self.next_response_body=(body)
    @next_response_body = body
  end
end

RSpec.describe "Property 4: Streaming Body Integrity" do
  around do |example|
    server, thread, port = StreamingBodyServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  def make_pool
    AwsCrt::Http::ConnectionPool.new("http://127.0.0.1:#{@port}")
  end

  def request_headers
    [["Host", "127.0.0.1:#{@port}"]]
  end

  # Generate a random body of binary bytes (0x00..0xFF) with a random
  # length. This exercises the full byte range, not just printable ASCII,
  # to catch encoding or truncation bugs.
  def random_body(max_size = 4096)
    len = rand(0..max_size)
    len.times.map { rand(0..255).chr }.join.b
  end

  it "concatenation of streamed chunks equals the buffered body" do
    property_of {
      range(0, 4096)
    }.check(20) do |body_size|
      body = body_size.times.map { rand(0..255).chr }.join.b
      StreamingBodyServer.next_response_body = body

      pool = make_pool

      # Buffered request
      _status_b, _headers_b, buffered_body = pool.request(
        "GET", "/buffered", request_headers
      )

      # Streaming request — collect all yielded chunks
      StreamingBodyServer.next_response_body = body
      chunks = []
      _status_s, _headers_s = pool.request(
        "GET", "/streaming", request_headers
      ) { |chunk| chunks << chunk.b }

      streamed_body = chunks.join.b

      expect(streamed_body).to eq(buffered_body.b),
                               "Streaming body (#{streamed_body.bytesize} bytes from " \
                               "#{chunks.size} chunks) differs from buffered body " \
                               "(#{buffered_body.bytesize} bytes) for a #{body.bytesize}-byte response"
    end
  end
end
