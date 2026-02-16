# frozen_string_literal: true

# Feature: crt-http-client, Property 9: Multi-Threaded Request Safety
#
# For any number of concurrent Ruby threads (up to 2× max_connections)
# submitting requests through the same Handler to the same endpoint,
# all requests SHALL complete without raising thread-safety errors,
# and each response SHALL be correctly matched to its originating request.
#
# **Validates: Requirements 11.1, 11.2, 11.3**
#
# Strategy: We start a local echo server that reflects a unique
# X-Request-Id header back in the response body. Multiple Ruby threads
# share a single ConnectionPool and each sends a request with a unique
# identifier. We verify that every thread completes without error and
# that each response contains the correct identifier — proving there
# is no cross-contamination between concurrent requests.

require "socket"
require "json"
require "rantly"
require "rantly/rspec_extensions"
require "aws_crt"

# Echo server that reflects the request back as JSON, including all
# headers. Each connection is handled independently with Connection: close.
module ThreadSafetyEchoServer
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
    headers, content_length = read_headers(client)
    body = content_length.positive? ? client.read(content_length) : ""

    echo_json = JSON.generate(
      "method" => method, "path" => path,
      "headers" => headers, "body" => body
    )
    write_response(client, echo_json)
  ensure
    client&.close
  end

  def self.read_headers(client)
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
    [headers, content_length]
  end

  def self.write_response(client, body_json)
    head = "HTTP/1.1 200 OK\r\n" \
           "Content-Type: application/json\r\n" \
           "Content-Length: #{body_json.bytesize}\r\n" \
           "Connection: close\r\n\r\n"
    client.write(head)
    client.write(body_json)
  end
end

RSpec.describe "Property 9: Multi-Threaded Request Safety" do
  around do |example|
    server, thread, port = ThreadSafetyEchoServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  def make_pool
    AwsCrt::Http::ConnectionPool.new("http://127.0.0.1:#{@port}")
  end

  it "concurrent threads sharing a pool all receive correctly matched responses" do
    property_of {
      range(2, 10)
    }.check(15) do |num_threads|
      pool = make_pool

      # Each thread gets a unique request ID and path
      threads = num_threads.times.map do |i|
        request_id = "req-#{i}-#{rand(100_000..999_999)}"
        Thread.new(request_id) do |rid|
          headers = [
            ["Host", "127.0.0.1:#{@port}"],
            ["X-Request-Id", rid]
          ]
          status, _, resp_body = pool.request("GET", "/thread/#{rid}", headers)
          { request_id: rid, status: status, body: resp_body }
        end
      end

      # Collect results — any exception in a thread is re-raised here
      results = threads.map(&:value)

      # Every thread must have completed with HTTP 200
      results.each do |result|
        expect(result[:status]).to eq(200),
          "Thread #{result[:request_id]} got status #{result[:status]}, expected 200"
      end

      # Every response must echo back the correct request ID
      results.each do |result|
        echo = JSON.parse(result[:body])
        echoed_id = echo["headers"]["X-Request-Id"]
        expect(echoed_id).to eq(result[:request_id]),
          "Response cross-contamination: thread sent #{result[:request_id].inspect} " \
          "but received #{echoed_id.inspect}"

        echoed_path = echo["path"]
        expected_path = "/thread/#{result[:request_id]}"
        expect(echoed_path).to eq(expected_path),
          "Path mismatch: expected #{expected_path.inspect}, got #{echoed_path.inspect}"
      end

      # All request IDs in the results must be unique (no duplicates)
      ids = results.map { |r| r[:request_id] }
      expect(ids.uniq.size).to eq(ids.size),
        "Duplicate request IDs in results: #{ids.inspect}"
    end
  end

  it "concurrent threads with request bodies receive correctly matched responses" do
    property_of {
      range(2, 8)
    }.check(10) do |num_threads|
      pool = make_pool

      threads = num_threads.times.map do |i|
        request_id = "body-#{i}-#{rand(100_000..999_999)}"
        body = "payload-for-#{request_id}"
        Thread.new(request_id, body) do |rid, req_body|
          headers = [
            ["Host", "127.0.0.1:#{@port}"],
            ["X-Request-Id", rid],
            ["Content-Length", req_body.bytesize.to_s]
          ]
          status, _, resp_body = pool.request("POST", "/thread/#{rid}", headers, req_body)
          { request_id: rid, status: status, body: resp_body, sent_body: req_body }
        end
      end

      results = threads.map(&:value)

      results.each do |result|
        expect(result[:status]).to eq(200),
          "Thread #{result[:request_id]} got status #{result[:status]}, expected 200"

        echo = JSON.parse(result[:body])

        echoed_id = echo["headers"]["X-Request-Id"]
        expect(echoed_id).to eq(result[:request_id]),
          "Response cross-contamination: sent #{result[:request_id].inspect}, " \
          "received #{echoed_id.inspect}"

        expect(echo["body"]).to eq(result[:sent_body]),
          "Body mismatch for #{result[:request_id]}: " \
          "sent #{result[:sent_body].inspect}, got #{echo["body"].inspect}"
      end
    end
  end
end
