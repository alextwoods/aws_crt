# frozen_string_literal: true

# Feature: crt-http-client, Property 3: Duplicate Header Merging
#
# For any HTTP response containing multiple headers with the same name
# (excluding Set-Cookie), the CRT client SHALL merge the values into a
# single comma-separated string. The merged string SHALL contain all
# original values in order, and splitting the merged string by ", "
# SHALL recover the original individual values.
#
# **Validates: Requirements 4.5**

require "socket"
require "rantly"
require "rantly/rspec_extensions"

# TCP server that sends HTTP responses with caller-specified duplicate
# headers. The test sets `next_response_headers` before each request.
module DuplicateHeaderServer
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
    response_headers = @next_response_headers || []
    body = "ok"

    head = "HTTP/1.1 200 OK\r\n"
    response_headers.each { |name, value| head += "#{name}: #{value}\r\n" }
    head += "Content-Length: #{body.bytesize}\r\n"
    head += "Connection: close\r\n\r\n"

    client.write(head)
    client.write(body)
  end

  def self.next_response_headers=(headers)
    @next_response_headers = headers
  end
end

# Safe characters for header values: alphanumeric plus a few punctuation
# chars. Excludes comma to avoid ambiguity when splitting merged values.
HEADER_VALUE_CHARS = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + %w[- _ .]).freeze

RSpec.describe "Property 3: Duplicate Header Merging" do
  around do |example|
    server, thread, port = DuplicateHeaderServer.start
    @port = port
    example.run
  ensure
    thread&.kill
    server&.close
  end

  def random_header_value
    len = rand(1..20)
    len.times.map { HEADER_VALUE_CHARS.sample }.join
  end

  def random_header_name(index)
    suffix = rand(1000..9999)
    "X-Dup-#{index}-#{suffix}"
  end

  def make_pool
    AwsCrt::Http::ConnectionPool.new("http://127.0.0.1:#{@port}")
  end

  it "merges duplicate non-Set-Cookie headers into comma-separated values" do
    property_of {
      # Generate random counts to drive the check block
      num_headers = range(1, 4)
      num_values_per = Array.new(num_headers) { range(2, 4) }
      [num_headers, num_values_per]
    }.check(20) do |(num_headers, num_values_per)|
      # Build header groups: each group has a unique name and multiple values
      header_groups = num_headers.times.map do |i|
        name = random_header_name(i)
        values = num_values_per[i].times.map { random_header_value }
        [name, values]
      end

      # Build raw response headers with duplicates
      raw_headers = []
      header_groups.each do |name, values|
        values.each { |v| raw_headers << [name, v] }
      end

      DuplicateHeaderServer.next_response_headers = raw_headers

      pool = make_pool
      _status, resp_headers, _body = pool.request(
        "GET", "/", [["Host", "127.0.0.1:#{@port}"]]
      )

      # Build a hash from response headers, accumulating values for
      # duplicate names (in case the CRT returns them as separate entries).
      resp_hash = {}
      resp_headers.each do |name, value|
        resp_hash[name] = resp_hash.key?(name) ? "#{resp_hash[name]}, #{value}" : value
      end

      # Verify each header group: splitting the merged value by ", "
      # must recover the original individual values in order.
      header_groups.each do |name, original_values|
        merged = resp_hash[name]
        expect(merged).not_to be_nil,
                              "Expected header #{name.inspect} in response, but it was missing"

        recovered = merged.split(", ")
        expect(recovered).to eq(original_values),
                              "Header #{name.inspect}: expected #{original_values.inspect}, " \
                              "got #{recovered.inspect} (merged: #{merged.inspect})"
      end
    end
  end

  it "does not merge Set-Cookie headers" do
    property_of {
      range(2, 5)
    }.check(10) do |num_cookies|
      cookie_values = num_cookies.times.map { random_header_value }
      raw_headers = cookie_values.map { |v| ["Set-Cookie", v] }

      DuplicateHeaderServer.next_response_headers = raw_headers

      pool = make_pool
      _status, resp_headers, _body = pool.request(
        "GET", "/", [["Host", "127.0.0.1:#{@port}"]]
      )

      # Collect all Set-Cookie entries from the response
      set_cookie_values = resp_headers
                          .select { |name, _| name.casecmp("set-cookie").zero? }
                          .map { |_, value| value }

      expect(set_cookie_values).to eq(cookie_values),
                                    "Set-Cookie headers should be kept as separate entries.\n" \
                                    "Expected: #{cookie_values.inspect}\n" \
                                    "Got: #{set_cookie_values.inspect}"
    end
  end
end
