# frozen_string_literal: true

# Feature: crt-http-client, Property 1: CRT Resource Initialization Idempotence
#
# For any number of calls to CrtRuntime.get() from any number of Ruby threads,
# the returned runtime object SHALL be the same instance, and the underlying
# CRT resources (Event_Loop_Group, Host_Resolver, Client_Bootstrap) SHALL be
# initialized exactly once.
#
# **Validates: Requirements 2.4**
#
# Since CrtRuntime is not directly exposed to Ruby, we observe idempotence
# through the ConnectionPool: creating pools from multiple concurrent threads
# must all succeed (proving the shared runtime initialized correctly) and the
# pools must all function (proving the shared resources are valid).

require "socket"
require "rantly"
require "rantly/rspec_extensions"

RSpec.describe "Property 1: CRT Resource Initialization Idempotence" do
  # Minimal TCP server that accepts connections and sends a valid HTTP response.
  def with_http_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        # Consume the request
        while (line = client.gets) && line.strip != ""
          # read headers
        end
        response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        client.write(response)
        client.close
      rescue IOError, Errno::EPIPE
        break
      end
    end

    yield port
  ensure
    thread&.kill
    server&.close
  end

  it "concurrent pool creation from random thread counts always succeeds" do
    with_http_server do |port|
      property_of {
        # Generate between 2 and 8 threads, each creating 1-3 pools
        num_threads = range(2, 8)
        pools_per_thread = range(1, 3)
        [num_threads, pools_per_thread]
      }.check(10) do |(num_threads, pools_per_thread)|
        endpoint = "http://127.0.0.1:#{port}"
        results = Array.new(num_threads)
        errors = []
        mutex = Mutex.new

        threads = num_threads.times.map do |i|
          Thread.new do
            thread_pools = []
            pools_per_thread.times do
              pool = AwsCrt::Http::ConnectionPool.new(endpoint)
              thread_pools << pool
            end
            results[i] = thread_pools
          rescue => e
            mutex.synchronize { errors << e }
          end
        end

        threads.each(&:join)

        # All threads must complete without errors — this proves the
        # runtime initialization is thread-safe and idempotent.
        expect(errors).to be_empty,
          "Expected no errors from concurrent pool creation, got: #{errors.map(&:message)}"

        # Every thread must have created the expected number of pools.
        results.each_with_index do |pools, i|
          expect(pools).not_to be_nil, "Thread #{i} produced nil result"
          expect(pools.length).to eq(pools_per_thread)
        end
      end
    end
  end

  it "pools created from different threads all produce valid responses" do
    with_http_server do |port|
      property_of {
        range(2, 6)
      }.check(10) do |num_threads|
        endpoint = "http://127.0.0.1:#{port}"
        responses = Array.new(num_threads)
        errors = []
        mutex = Mutex.new

        threads = num_threads.times.map do |i|
          Thread.new do
            pool = AwsCrt::Http::ConnectionPool.new(endpoint)
            headers = [["Host", "127.0.0.1:#{port}"]]
            status, _resp_headers, body = pool.request("GET", "/test", headers)
            responses[i] = { status: status, body: body }
          rescue => e
            mutex.synchronize { errors << e }
          end
        end

        threads.each(&:join)

        expect(errors).to be_empty,
          "Expected no errors from concurrent requests, got: #{errors.map(&:message)}"

        # Every thread's pool must have produced a valid response,
        # proving the shared CRT runtime resources are functional.
        responses.each_with_index do |resp, i|
          expect(resp).not_to be_nil, "Thread #{i} produced nil response"
          expect(resp[:status]).to eq(200),
            "Thread #{i} got status #{resp[:status]}, expected 200"
          expect(resp[:body]).to eq("ok"),
            "Thread #{i} got unexpected body: #{resp[:body].inspect}"
        end
      end
    end
  end
end
