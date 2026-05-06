# frozen_string_literal: true

# Unit tests for response_target argument validation in AwsCrt::Http::Client.
#
# These tests verify that the CRT client correctly validates the
# response_target keyword argument and raises appropriate errors
# for invalid inputs.

require "socket"
require "pathname"
require "tempfile"

RSpec.describe AwsCrt::Http::Client, "response_target validation" do
  # A minimal HTTP/1.1 server that always returns 200.
  def with_echo_server
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        # Read request line and headers
        request_line = client.gets
        content_length = 0
        while (line = client.gets) && line.strip != ""
          key, value = line.split(":", 2)
          content_length = value.strip.to_i if key&.strip&.downcase == "content-length"
        end
        # Read body if present
        client.read(content_length) if content_length > 0

        response_body = "OK"
        response = "HTTP/1.1 200 OK\r\n" \
                   "Content-Length: #{response_body.bytesize}\r\n" \
                   "Connection: close\r\n" \
                   "\r\n" \
                   "#{response_body}"
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

  let(:client) { described_class.new }

  describe "invalid response_target type" do
    it "raises ArgumentError for an Integer" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: 42)
        }.to raise_error(ArgumentError, /response_target must be/)
      end
    end

    it "raises ArgumentError for an Array" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: [1, 2, 3])
        }.to raise_error(ArgumentError, /response_target must be/)
      end
    end

    it "raises ArgumentError for a Symbol" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: :invalid)
        }.to raise_error(ArgumentError, /response_target must be/)
      end
    end
  end

  describe "response_target + block conflict" do
    it "raises ArgumentError when both response_target and block are given" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: proc { |_b, _h| }) do |_chunk|
            # block
          end
        }.to raise_error(ArgumentError, /response_target and block are mutually exclusive/)
      end
    end
  end

  describe "offset hash validation" do
    it "raises ArgumentError when hash is missing :path" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: { offset: 0 })
        }.to raise_error(ArgumentError, /must include :path.*:offset/)
      end
    end

    it "raises ArgumentError when hash is missing :offset" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: { path: "/tmp/test.bin" })
        }.to raise_error(ArgumentError, /must include :path.*:offset/)
      end
    end

    it "raises ArgumentError when offset is negative" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: { path: "/tmp/test.bin", offset: -1 })
        }.to raise_error(ArgumentError, /offset must be non-negative/)
      end
    end

    it "raises ArgumentError when :path is not a String" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: { path: 123, offset: 0 })
        }.to raise_error(ArgumentError, /must include :path.*:offset/)
      end
    end

    it "raises ArgumentError for an empty hash" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        expect {
          client.request(endpoint, "GET", "/", headers, response_target: {})
        }.to raise_error(ArgumentError, /must include :path.*:offset/)
      end
    end
  end

  describe "valid response_target types are accepted" do
    it "accepts a Proc" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        # Should not raise - validation passes (dispatch is a later task)
        response = client.request(endpoint, "GET", "/", headers, response_target: proc { |_b, _h| })
        expect(response.status_code).to eq(200)
      end
    end

    it "accepts a String file path" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        # Should not raise - validation passes
        response = client.request(endpoint, "GET", "/", headers, response_target: "/tmp/test_response_target.bin")
        expect(response.status_code).to eq(200)
      end
    end

    it "accepts a Pathname" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        # Should not raise - validation passes
        response = client.request(endpoint, "GET", "/", headers, response_target: Pathname.new("/tmp/test_response_target.bin"))
        expect(response.status_code).to eq(200)
      end
    end

    it "accepts a valid offset hash" do
      with_echo_server do |port|
        endpoint = "http://127.0.0.1:#{port}"
        headers = [["Host", "127.0.0.1:#{port}"]]

        # Should not raise - validation passes
        response = client.request(endpoint, "GET", "/", headers, response_target: { path: "/tmp/test_response_target.bin", offset: 0 })
        expect(response.status_code).to eq(200)
      end
    end
  end
end
