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

  describe "SharableStringIO Ractor support" do
    describe "sending SharableStringIO between Ractors" do
      it "can send a SharableStringIO from one Ractor to another" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          # Create a SharableStringIO in one Ractor, send it to another for reading
          producer = Ractor.new(client, port) do |c, p|
            _status, _headers, sio = c.request(
              "http://127.0.0.1:#{p}",
              "GET", "/sio-transfer",
              [["Host", "127.0.0.1:#{p}"]],
              streaming_io: true
            )
            sio
          end

          sio = producer.value

          # Send the SharableStringIO to a consumer Ractor
          consumer = Ractor.new(sio) do |io|
            io.read
          end

          body = consumer.value
          expect(body).to include("GET /sio-transfer")
        end
      end

      it "SharableStringIO is Ractor.shareable?" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          result = Ractor.new(client, port) do |c, p|
            _status, _headers, sio = c.request(
              "http://127.0.0.1:#{p}",
              "GET", "/shareable-check",
              [["Host", "127.0.0.1:#{p}"]],
              streaming_io: true
            )
            [Ractor.shareable?(sio), sio.frozen?]
          end.value

          shareable, frozen = result
          expect(shareable).to be true
          expect(frozen).to be true
        end
      end
    end

    describe "multiple Ractors sharing a client with streaming_io" do
      it "each Ractor gets its own independent SharableStringIO" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          ractor_count = 4
          ractors = ractor_count.times.map do |i|
            Ractor.new(client, port, i) do |c, p, idx|
              _status, _headers, sio = c.request(
                "http://127.0.0.1:#{p}",
                "GET", "/streaming-#{idx}",
                [["Host", "127.0.0.1:#{p}"]],
                streaming_io: true
              )
              [idx, sio.read, sio.size]
            end
          end

          results = ractors.map(&:value)

          expect(results.size).to eq(ractor_count)
          results.each do |idx, body, size|
            expect(body).to include("GET /streaming-#{idx}")
            expect(size).to eq(body.bytesize)
          end
        end
      end

      it "SharableStringIO instances from different Ractors are independent" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          # Create SharableStringIO instances in separate Ractors
          ractors = 3.times.map do |i|
            Ractor.new(client, port, i) do |c, p, idx|
              _status, _headers, sio = c.request(
                "http://127.0.0.1:#{p}",
                "GET", "/independent-#{idx}",
                [["Host", "127.0.0.1:#{p}"]],
                streaming_io: true
              )
              sio
            end
          end

          sios = ractors.map(&:value)

          # Each SharableStringIO should have different content
          bodies = sios.map(&:read)
          bodies.each_with_index do |body, i|
            expect(body).to include("GET /independent-#{i}")
          end

          # Reading one doesn't affect the others
          sios.each(&:rewind)
          sios.each_with_index do |sio, i|
            expect(sio.read).to include("GET /independent-#{i}")
          end
        end
      end
    end

    describe "concurrent reads from multiple Ractors on the same SharableStringIO" do
      it "multiple Ractors can read the same SharableStringIO without corruption" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          # Create a SharableStringIO with known content
          _status, _headers, sio = client.request(
            "http://127.0.0.1:#{port}",
            "GET", "/shared-read",
            [["Host", "127.0.0.1:#{port}"]],
            streaming_io: true
          )

          expected_content = sio.read
          sio.rewind

          # Multiple Ractors read the same SharableStringIO concurrently
          ractor_count = 4
          ractors = ractor_count.times.map do
            Ractor.new(sio) do |io|
              # Each Ractor has its own read position (pos is per-call via AtomicUsize),
              # but since the object is shared, we rewind and read to verify no corruption.
              # Note: with shared state, each Ractor's rewind/read may interleave,
              # but the data itself should never be corrupted.
              io.rewind
              io.read
            end
          end

          results = ractors.map(&:value)

          # All Ractors should get the same non-corrupted content
          results.each do |body|
            expect(body).to eq(expected_content)
          end
        end
      end

      it "concurrent partial reads from multiple Ractors produce non-corrupted data" do
        with_echo_server do |port|
          client = AwsCrt::Http::Client.new
          client.freeze

          # Create a SharableStringIO with known content
          _status, _headers, sio = client.request(
            "http://127.0.0.1:#{port}",
            "GET", "/concurrent-partial",
            [["Host", "127.0.0.1:#{port}"]],
            streaming_io: true
          )

          full_content = sio.string

          # Multiple Ractors do partial reads concurrently.
          # Since pos is shared (AtomicUsize), interleaving is expected,
          # but each individual read chunk must contain valid bytes from the buffer.
          ractor_count = 4
          ractors = ractor_count.times.map do
            Ractor.new(sio) do |io|
              io.rewind
              chunks = []
              chunk_size = 4
              loop do
                chunk = io.read(chunk_size)
                break if chunk.nil?
                chunks << chunk
              end
              chunks
            end
          end

          results = ractors.map(&:value)

          # Verify no corruption: every byte in every chunk must exist
          # in the original buffer at some valid position. Each chunk must
          # be a contiguous slice of the original buffer.
          results.each do |chunks|
            chunks.each do |chunk|
              # Each chunk should be a contiguous subsequence of full_content
              expect(full_content).to include(chunk)
            end
          end
        end
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
