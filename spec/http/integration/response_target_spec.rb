# frozen_string_literal: true

# Integration tests for the response_target feature of the CRT HTTP client.
#
# These tests verify end-to-end behavior of response_target with a real
# TCP server, covering file targets, Proc targets, offset file targets,
# non-success responses, on_data interaction, and GVL release.

require "English"
require "socket"
require "json"
require "pathname"
require "tmpdir"
require "fileutils"

# A configurable TCP server for response_target integration tests.
# Supports setting the response status code, body, and custom headers
# per-request via class-level configuration.
class ResponseTargetTestServer
  STATUS_TEXTS = {
    200 => "OK", 201 => "Created", 206 => "Partial Content",
    404 => "Not Found", 500 => "Internal Server Error"
  }.freeze

  attr_reader :port

  def self.start(status: 200, body: "hello", headers: {})
    server = new(status: status, body: body, headers: headers)
    server.start
    server
  end

  def initialize(status:, body:, headers:)
    @status = status
    @body = body.b
    @headers = headers
    @server = nil
    @thread = nil
    @port = nil
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { accept_loop }
  end

  def stop
    @thread&.kill
    @server&.close
  end

  def endpoint
    "http://127.0.0.1:#{@port}"
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      Thread.new(client) { |c| handle_connection(c) }
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle_connection(client)
    drain_request(client)
    write_response(client)
  rescue IOError, Errno::EPIPE, Errno::ECONNRESET
    # Client disconnected
  ensure
    client&.close
  end

  def drain_request(client)
    request_line = client.gets
    return unless request_line

    content_length = read_content_length(client)
    client.read(content_length) if content_length > 0
  end

  def read_content_length(client)
    content_length = 0
    while (line = client.gets) && line.strip != ""
      key, value = line.split(":", 2)
      content_length = value.strip.to_i if key&.strip&.downcase == "content-length"
    end
    content_length
  end

  def write_response(client)
    status_text = STATUS_TEXTS[@status] || "Status"
    head = "HTTP/1.1 #{@status} #{status_text}\r\n"
    head += "Content-Length: #{@body.bytesize}\r\n"
    @headers.each { |name, value| head += "#{name}: #{value}\r\n" }
    head += "Connection: close\r\n\r\n"

    client.write(head)
    client.write(@body)
  end
end

RSpec.describe "response_target integration" do
  let(:client) { AwsCrt::Http::Client.new }

  def host_header(server)
    ["Host", "127.0.0.1:#{server.port}"]
  end

  describe "file target end-to-end" do
    it "writes response body to file, returns empty SharableStringIO, and sets response_target_info" do
      body_content = "The quick brown fox jumps over the lazy dog. " * 100
      server = ResponseTargetTestServer.start(status: 200, body: body_content, headers: { "X-Test" => "file-target" })
      path = File.join(Dir.tmpdir, "response_target_integ_file_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/download", [host_header(server)],
          streaming_io: true, response_target: path
        )

        # Verify file contains exact response bytes
        expect(File.exist?(path)).to be(true)
        file_content = File.binread(path)
        expect(file_content).to eq(body_content.b)

        # Verify response body is empty SharableStringIO
        expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
        expect(response.body.size).to eq(0)

        # Verify response_target_info is correct
        info = response.response_target_info
        expect(info).to be_a(Hash)
        expect(info[:type]).to eq(:file)
        expect(info[:path]).to eq(path)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end

    it "works with a Pathname target" do
      body_content = "Pathname target test body content"
      server = ResponseTargetTestServer.start(status: 200, body: body_content)
      path = File.join(Dir.tmpdir, "response_target_integ_pathname_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/download", [host_header(server)],
          streaming_io: true, response_target: Pathname.new(path)
        )

        expect(File.binread(path)).to eq(body_content.b)
        expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
        expect(response.body.size).to eq(0)
        expect(response.response_target_info[:type]).to eq(:file)
        expect(response.response_target_info[:path]).to eq(path)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end
  end

  describe "Proc target end-to-end" do
    it "calls Proc with body and headers, returns empty SharableStringIO" do
      body_content = "Proc target integration test body"
      server = ResponseTargetTestServer.start(
        status: 200, body: body_content,
        headers: { "X-Custom" => "proc-value", "Content-Type" => "application/octet-stream" }
      )

      received_body = nil
      received_headers = nil
      call_count = 0

      target_proc = proc do |b, h|
        call_count += 1
        received_body = b
        received_headers = h
      end

      begin
        response = client.request(
          server.endpoint, "GET", "/callback", [host_header(server)],
          streaming_io: true, response_target: target_proc
        )

        # Verify Proc receives exact body and headers
        expect(call_count).to eq(1)
        expect(received_body.b).to eq(body_content.b)
        expect(received_headers).to be_a(Hash)
        expect(received_headers["X-Custom"]).to eq("proc-value")

        # Verify response body is empty SharableStringIO
        expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
        expect(response.body.size).to eq(0)

        # Verify response_target_info
        expect(response.response_target_info).to eq({ type: :proc })
      ensure
        server.stop
      end
    end
  end

  describe "offset file target end-to-end" do
    it "writes response body at the specified offset" do
      body_content = "OFFSET_DATA_HERE"
      offset = 64
      server = ResponseTargetTestServer.start(status: 200, body: body_content)
      path = File.join(Dir.tmpdir, "response_target_integ_offset_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/range", [host_header(server)],
          streaming_io: true, response_target: { path: path, offset: offset }
        )

        # Verify file contains bytes at correct offset
        expect(File.exist?(path)).to be(true)
        file_content = File.binread(path)

        # File should be at least offset + body length
        expect(file_content.bytesize).to be >= (offset + body_content.bytesize)

        # Bytes before offset should be null
        expect(file_content[0, offset]).to eq("\x00" * offset)

        # Bytes at offset should match body
        expect(file_content[offset, body_content.bytesize]).to eq(body_content.b)

        # Verify response_target_info
        info = response.response_target_info
        expect(info[:type]).to eq(:offset_file)
        expect(info[:path]).to eq(path)
        expect(info[:offset]).to eq(offset)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end

    it "writes at offset 0 (equivalent to file target)" do
      body_content = "zero offset body"
      server = ResponseTargetTestServer.start(status: 200, body: body_content)
      path = File.join(Dir.tmpdir, "response_target_integ_offset0_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/range", [host_header(server)],
          streaming_io: true, response_target: { path: path, offset: 0 }
        )

        expect(File.binread(path)).to eq(body_content.b)
        expect(response.response_target_info[:type]).to eq(:offset_file)
        expect(response.response_target_info[:offset]).to eq(0)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end
  end

  describe "non-success response with target" do
    it "does not create file and returns error body when status is 404" do
      error_body = '{"error": "Not Found", "message": "The requested resource does not exist"}'
      server = ResponseTargetTestServer.start(status: 404, body: error_body)
      path = File.join(Dir.tmpdir, "response_target_integ_nosuccess_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/missing", [host_header(server)],
          streaming_io: true, response_target: path
        )

        # Verify file is NOT created
        expect(File.exist?(path)).to be(false)

        # Verify response body contains the error body
        response_body = response.body.is_a?(AwsCrt::Http::SharableStringIO) ? response.body.read : response.body
        expect(response_body.b).to eq(error_body.b)

        # Verify response_target_info is nil
        expect(response.response_target_info).to be_nil
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end

    it "does not call Proc when status is 500" do
      error_body = "Internal Server Error"
      server = ResponseTargetTestServer.start(status: 500, body: error_body)
      proc_called = false
      target_proc = proc { |_b, _h| proc_called = true }

      begin
        response = client.request(
          server.endpoint, "GET", "/error", [host_header(server)],
          streaming_io: true, response_target: target_proc
        )

        expect(proc_called).to be(false)
        response_body = response.body.is_a?(AwsCrt::Http::SharableStringIO) ? response.body.read : response.body
        expect(response_body.b).to eq(error_body.b)
        expect(response.response_target_info).to be_nil
      ensure
        server.stop
      end
    end

    it "does not create file for offset target when status is 404" do
      error_body = "resource not found"
      server = ResponseTargetTestServer.start(status: 404, body: error_body)
      path = File.join(Dir.tmpdir, "response_target_integ_offset_nosuccess_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        response = client.request(
          server.endpoint, "GET", "/missing", [host_header(server)],
          streaming_io: true, response_target: { path: path, offset: 128 }
        )

        expect(File.exist?(path)).to be(false)
        expect(response.response_target_info).to be_nil
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end
  end

  describe "on_data + response_target interaction" do
    it "on_data receives body bytes while file target also gets them" do
      body_content = "on_data interaction test body " * 50
      server = ResponseTargetTestServer.start(status: 200, body: body_content)
      path = File.join(Dir.tmpdir, "response_target_integ_ondata_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      on_data_chunks = []
      on_data_listener = ->(chunk) { on_data_chunks << chunk.b }

      begin
        response = client.request(
          server.endpoint, "GET", "/data", [host_header(server)],
          streaming_io: true,
          response_target: path,
          on_data: [on_data_listener]
        )

        # Verify on_data receives actual body bytes
        on_data_body = on_data_chunks.join.b
        expect(on_data_body).to eq(body_content.b)

        # Verify file contains the body bytes
        expect(File.binread(path)).to eq(body_content.b)

        # Verify response body is empty SharableStringIO
        expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
        expect(response.body.size).to eq(0)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end

    it "on_data receives body bytes while Proc target also gets them" do
      body_content = "on_data with proc target"
      server = ResponseTargetTestServer.start(status: 200, body: body_content)

      on_data_chunks = []
      on_data_listener = ->(chunk) { on_data_chunks << chunk.b }

      proc_body = nil
      target_proc = proc { |b, _h| proc_body = b }

      begin
        response = client.request(
          server.endpoint, "GET", "/data", [host_header(server)],
          streaming_io: true,
          response_target: target_proc,
          on_data: [on_data_listener]
        )

        # Both on_data and Proc should receive the body
        on_data_body = on_data_chunks.join.b
        expect(on_data_body).to eq(body_content.b)
        expect(proc_body.b).to eq(body_content.b)

        # Response body should be empty
        expect(response.body.size).to eq(0)
      ensure
        server.stop
      end
    end
  end

  describe "GVL release during file write" do
    it "allows other threads to make progress during a large file write" do
      # Use a large body (1MB) to ensure the file write takes measurable time
      large_body = "x" * (1024 * 1024)
      server = ResponseTargetTestServer.start(status: 200, body: large_body)
      path = File.join(Dir.tmpdir, "response_target_integ_gvl_#{$PROCESS_ID}_#{rand(100_000)}.bin")

      begin
        # Track whether a concurrent thread can make progress during the request.
        # If the GVL is released during file write, the counter thread should
        # be able to increment its counter.
        counter = 0
        stop_flag = false

        counter_thread = Thread.new do
          counter += 1 until stop_flag
        end

        # Give the counter thread a moment to start
        sleep(0.01)
        counter_before = counter

        # Make the request with file target (GVL should be released during write)
        response = client.request(
          server.endpoint, "GET", "/large", [host_header(server)],
          streaming_io: true, response_target: path
        )

        counter_after = counter
        stop_flag = true
        counter_thread.join(2)

        # The counter should have advanced during the request, proving the GVL
        # was released at some point. With a 1MB write, the counter thread
        # should have had opportunities to run.
        expect(counter_after).to be > counter_before,
                                 "Counter thread should have made progress during file write " \
                                 "(before=#{counter_before}, after=#{counter_after}), " \
                                 "indicating GVL was released"

        # Verify the file was written correctly
        expect(File.exist?(path)).to be(true)
        expect(File.size(path)).to eq(large_body.bytesize)
        expect(response.body.size).to eq(0)
      ensure
        FileUtils.rm_f(path)
        server.stop
      end
    end
  end
end
