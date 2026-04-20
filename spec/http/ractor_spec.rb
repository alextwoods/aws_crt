# frozen_string_literal: true

# Ractor integration tests for AwsCrt::Http::Client.
#
# Verifies that the CRT HTTP client can be frozen, shared across
# Ractors, and used for concurrent HTTP requests from multiple
# Ractors in parallel.

require "socket"

RSpec.describe "AwsCrt::Http::Client Ractor support" do
  # A minimal HTTP/1.1 server that handles multiple connections.
  # Each request gets an echo response with the request method, path,
  # and a server-assigned request ID for correlation.
  def with_echo_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    request_counter = 0
    counter_mutex = Mutex.new

    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |conn|
          request_line = conn.gets
          # Read headers
          content_length = 0
          while (line = conn.gets) && line.strip != ""
            if line.strip.downcase.start_with?("content-length:")
              content_length = line.split(":", 2).last.strip.to_i
            end
          end
          body = content_length > 0 ? conn.read(content_length) : ""

          method, path, = request_line&.split(" ")
          req_id = counter_mutex.synchronize { request_counter += 1 }

          response_body = "#{method} #{path} req_id=#{req_id} body=#{body}"
          response = "HTTP/1.1 200 OK\r\n" \
                     "Content-Length: #{response_body.bytesize}\r\n" \
                     "X-Request-Id: #{req_id}\r\n" \
                     "Connection: close\r\n" \
                     "\r\n" \
                     "#{response_body}"
          conn.write(response)
          conn.close
        rescue IOError, Errno::EPIPE
          # ignore
        end
      rescue IOError
        break
      end
    end

    yield port
  ensure
    thread&.kill
    server&.close
  end

  describe "Ractor.shareable?" do
    it "is shareable when frozen" do
      client = AwsCrt::Http::Client.new
      client.freeze
      expect(Ractor.shareable?(client)).to be true
    end

    it "is not shareable when not frozen" do
      client = AwsCrt::Http::Client.new
      expect(Ractor.shareable?(client)).to be false
    end

    it "can be made shareable with Ractor.make_shareable" do
      client = AwsCrt::Http::Client.new
      Ractor.make_shareable(client)
      expect(Ractor.shareable?(client)).to be true
      expect(client.frozen?).to be true
    end
  end

  describe "single Ractor usage" do
    it "can make HTTP requests from a non-main Ractor" do
      with_echo_server do |port|
        client = AwsCrt::Http::Client.new
        client.freeze

        result = Ractor.new(client, port) do |c, p|
          status, _headers, body = c.request(
            "http://127.0.0.1:#{p}",
            "GET", "/from-ractor",
            [["Host", "127.0.0.1:#{p}"]]
          )
          [status, body]
        end.value

        status, body = result
        expect(status).to eq(200)
        expect(body).to include("GET /from-ractor")
      end
    end
  end

  describe "multi-Ractor parallel requests" do
    it "handles concurrent requests from multiple Ractors" do
      with_echo_server do |port|
        client = AwsCrt::Http::Client.new
        client.freeze

        ractor_count = 4
        ractors = ractor_count.times.map do |i|
          Ractor.new(client, port, i) do |c, p, idx|
            status, _headers, body = c.request(
              "http://127.0.0.1:#{p}",
              "GET", "/ractor-#{idx}",
              [["Host", "127.0.0.1:#{p}"]]
            )
            [idx, status, body]
          end
        end

        results = ractors.map(&:value)

        expect(results.size).to eq(ractor_count)
        results.each do |idx, status, body|
          expect(status).to eq(200)
          expect(body).to include("GET /ractor-#{idx}")
        end
      end
    end

    it "handles concurrent POST requests with bodies from multiple Ractors" do
      with_echo_server do |port|
        client = AwsCrt::Http::Client.new
        client.freeze

        ractor_count = 4
        ractors = ractor_count.times.map do |i|
          Ractor.new(client, port, i) do |c, p, idx|
            body = "payload-#{idx}"
            status, _headers, resp_body = c.request(
              "http://127.0.0.1:#{p}",
              "POST", "/post-#{idx}",
              [["Host", "127.0.0.1:#{p}"], ["Content-Length", body.bytesize.to_s]],
              body
            )
            [idx, status, resp_body]
          end
        end

        results = ractors.map(&:value)

        results.each do |idx, status, resp_body|
          expect(status).to eq(200)
          expect(resp_body).to include("POST /post-#{idx}")
          expect(resp_body).to include("payload-#{idx}")
        end
      end
    end

    it "shares a single client across Ractors hitting the same endpoint" do
      with_echo_server do |port|
        client = AwsCrt::Http::Client.new
        client.freeze

        # All Ractors use the same endpoint — the client should
        # internally reuse the same connection pool.
        ractor_count = 4
        ractors = ractor_count.times.map do |i|
          Ractor.new(client, port, i) do |c, p, idx|
            status, _headers, body = c.request(
              "http://127.0.0.1:#{p}",
              "GET", "/shared-pool-#{idx}",
              [["Host", "127.0.0.1:#{p}"]]
            )
            [idx, status, body]
          end
        end

        results = ractors.map(&:value)
        expect(results.size).to eq(ractor_count)
        results.each do |idx, status, body|
          expect(status).to eq(200)
          expect(body).to include("/shared-pool-#{idx}")
        end
      end
    end
  end

  describe "streaming from Ractors" do
    it "supports streaming responses from a non-main Ractor" do
      with_echo_server do |port|
        client = AwsCrt::Http::Client.new
        client.freeze

        result = Ractor.new(client, port) do |c, p|
          chunks = []
          status, _headers = c.request(
            "http://127.0.0.1:#{p}",
            "GET", "/stream-ractor",
            [["Host", "127.0.0.1:#{p}"]]
          ) { |chunk| chunks << chunk }
          [status, chunks.join]
        end.value

        status, body = result
        expect(status).to eq(200)
        expect(body).to include("GET /stream-ractor")
      end
    end
  end

  describe "error handling in Ractors" do
    it "propagates CRT errors from non-main Ractors" do
      client = AwsCrt::Http::Client.new
      client.freeze

      # Connect to a port that's not listening — should raise ConnectionError
      r = Ractor.new(client) do |c|
        begin
          c.request(
            "http://127.0.0.1:1",
            "GET", "/",
            [["Host", "127.0.0.1:1"]]
          )
          :no_error
        rescue AwsCrt::Http::Error => e
          e.class.name
        end
      end

      result = r.value
      # Should have caught an error (ConnectionError or TimeoutError)
      expect(result).to be_a(String)
      expect(result).to match(/AwsCrt::Http::(ConnectionError|TimeoutError|Error)/)
    end
  end
end
