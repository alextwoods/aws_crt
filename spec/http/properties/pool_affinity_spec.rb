# frozen_string_literal: true

# Feature: crt-http-client, Property 5: Multi-Endpoint Client Routing
#
# For any sequence of requests to a set of distinct endpoints, a single
# Client instance SHALL successfully route requests to the correct
# endpoint and return valid responses from each. The Client manages
# connection pools internally, so callers need only a single Client
# to reach multiple endpoints.
#
# **Validates: Requirements 8.5**

require "socket"
require "json"
require "rantly"
require "rantly/rspec_extensions"
require "aws_crt"

# Minimal echo server that includes the port in the response so we can
# verify which server handled the request.
module AffinityEchoServer
  def self.start
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new { accept_loop(server, port) }
    [server, thread, port]
  end

  def self.accept_loop(server, port)
    loop do
      client = server.accept
      handle(client, port)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # Client disconnected — continue accepting
    end
  end

  def self.handle(client, port)
    request_line = client.gets
    return unless request_line

    method, path, = request_line.strip.split(" ", 3)

    # Drain request headers
    nil while (line = client.gets) && line.strip != ""

    body = JSON.generate("method" => method, "path" => path, "port" => port)
    head = "HTTP/1.1 200 OK\r\n" \
           "Content-Type: application/json\r\n" \
           "Content-Length: #{body.bytesize}\r\n" \
           "Connection: close\r\n\r\n"
    client.write(head)
    client.write(body)
  ensure
    client&.close
  end
end

RSpec.describe "Property 5: Multi-Endpoint Client Routing" do
  it "a single Client routes requests to the correct endpoint among multiple servers" do
    property_of {
      range(2, 5)
    }.check(15) do |num_servers|
      servers = num_servers.times.map { AffinityEchoServer.start }

      begin
        client = AwsCrt::Http::Client.new

        # Send a request to each server and verify the response came
        # from the correct one (identified by port number).
        servers.each do |_server, _thread, port|
          endpoint = "http://127.0.0.1:#{port}"
          headers = [["Host", "127.0.0.1:#{port}"]]
          response = client.request(endpoint, "GET", "/affinity", headers)

          expect(response.status_code).to eq(200),
            "Request to port #{port} returned status #{response.status_code}, expected 200"

          echo = JSON.parse(response.body)
          expect(echo["port"]).to eq(port),
            "Expected response from port #{port}, got port #{echo["port"]}"
          expect(echo["path"]).to eq("/affinity"),
            "Expected path /affinity, got #{echo["path"].inspect}"
        end

        # Send a second round to verify repeated requests still route correctly
        servers.each do |_server, _thread, port|
          endpoint = "http://127.0.0.1:#{port}"
          headers = [["Host", "127.0.0.1:#{port}"]]
          response = client.request(endpoint, "GET", "/again", headers)

          expect(response.status_code).to eq(200)
          echo = JSON.parse(response.body)
          expect(echo["port"]).to eq(port),
            "Repeated request: expected port #{port}, got #{echo["port"]}"
        end
      ensure
        servers.each do |server, thread, _port|
          thread&.kill
          server&.close
        end
      end
    end
  end
end
