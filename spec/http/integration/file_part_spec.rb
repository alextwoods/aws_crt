# frozen_string_literal: true

# Integration tests for using FilePart as a request body with the CRT HTTP client.
#
# Tests that FilePart can be passed as the body argument to client.request()
# and that the server receives the correct bytes.

require "json"
require "tmpdir"
require "securerandom"
require "support/test_server"

RSpec.describe "FilePart as request body" do
  before(:all) do
    @server = TestServer.start
    @client = AwsCrt::Http::Client.new
    @tmpdir = Dir.mktmpdir("file_part_integration")
  end

  after(:all) do
    @server&.stop
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def host_header
    ["Host", "127.0.0.1:#{@server.port}"]
  end

  def create_test_file(content)
    path = File.join(@tmpdir, "test_#{SecureRandom.hex(4)}.bin")
    File.binwrite(path, content)
    path
  end

  describe "sending a FilePart as request body" do
    it "sends the file part bytes as the request body" do
      content = "Hello from FilePart!"
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header, ["Content-Length", content.bytesize.to_s]],
        fp
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["body"]).to eq(content)
    end

    it "sends only the specified byte range" do
      full_content = "AAAA_PAYLOAD_BBBB"
      path = create_test_file(full_content)
      # Read only "PAYLOAD" (offset 5, size 7)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 5, size: 7)

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header, %w[Content-Length 7]],
        fp
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["body"]).to eq("PAYLOAD")
    end

    it "works with streaming_io: true" do
      content = "streaming_io body test"
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header, ["Content-Length", content.bytesize.to_s]],
        fp,
        streaming_io: true
      )

      expect(response.status_code).to eq(200)
      expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
      echo = JSON.parse(response.body.read)
      expect(echo["body"]).to eq(content)
    end

    it "works with on_data listeners" do
      content = "on_data listener test"
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      received = []
      listener = ->(chunk) { received << chunk }

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header, ["Content-Length", content.bytesize.to_s]],
        fp,
        on_data: [listener]
      )

      expect(response.status_code).to eq(200)
      expect(received).not_to be_empty
    end

    it "works with checksum_algorithms" do
      content = "checksum test body"
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header, ["Content-Length", content.bytesize.to_s], %w[X-Add-Checksum CRC32]],
        fp,
        streaming_io: true,
        checksum_algorithms: ["CRC32"]
      )

      expect(response.status_code).to eq(200)
      expect(response.checksum_algorithm).to eq("CRC32")
      expect(response.computed_checksum).not_to be_nil
    end

    it "works with a large file part (64KB)" do
      content = "x" * (64 * 1024)
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      response = @client.request(
        @server.endpoint, "PUT", "/large",
        [host_header, ["Content-Length", content.bytesize.to_s]],
        fp
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["body"].bytesize).to eq(64 * 1024)
    end

    it "sends an empty body for a zero-size FilePart" do
      path = create_test_file("some content")
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: 0)

      response = @client.request(
        @server.endpoint, "POST", "/upload",
        [host_header],
        fp
      )

      expect(response.status_code).to eq(200)
      echo = JSON.parse(response.body)
      expect(echo["body"]).to eq("")
    end
  end

  describe "Ractor integration with FilePart as body" do
    it "sends a FilePart body from within a Ractor" do
      content = "Ractor FilePart body"
      path = create_test_file(content)
      fp = AwsCrt::Http::FilePart.new(source: path, offset: 0, size: content.bytesize)

      client = AwsCrt::Http::Client.new
      client.freeze

      endpoint = @server.endpoint
      port = @server.port

      result = Ractor.new(client, fp, endpoint, port, content.bytesize) do |c, body, ep, p, len|
        response = c.request(
          ep, "POST", "/ractor-upload",
          [["Host", "127.0.0.1:#{p}"], ["Content-Length", len.to_s]],
          body
        )
        [response.status_code, response.body]
      end.value

      status, body = result
      expect(status).to eq(200)
      echo = JSON.parse(body)
      expect(echo["body"]).to eq(content)
    end
  end
end
