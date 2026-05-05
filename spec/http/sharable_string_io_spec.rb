# frozen_string_literal: true

# Unit tests for AwsCrt::Http::SharableStringIO.
#
# Tests the read-only, Ractor-safe IO interface backed by a native
# Rust buffer. Uses a local TCP echo server to create SharableStringIO
# instances with known content via `streaming_io: true`.

require "socket"
require "tmpdir"
require "stringio"

RSpec.describe AwsCrt::Http::SharableStringIO do
  # A minimal HTTP/1.1 server that returns a configurable response body.
  def with_echo_server(response_body: "Hello, SharableStringIO!")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        # Read request line and headers
        client.gets # request line
        while (line = client.gets) && line.strip != ""; end

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

  # Helper to create a SharableStringIO with known content via streaming_io.
  def create_sio_with_content(content)
    sio = nil
    with_echo_server(response_body: content) do |port|
      client = AwsCrt::Http::Client.new
      endpoint = "http://127.0.0.1:#{port}"
      headers = [["Host", "127.0.0.1:#{port}"]]
      _status, _headers, sio = client.request(endpoint, "GET", "/", headers, streaming_io: true)
    end
    sio
  end

  describe "#read" do
    context "with no arguments" do
      it "returns all remaining bytes from the current position" do
        sio = create_sio_with_content("Hello, World!")
        expect(sio.read).to eq("Hello, World!")
      end

      it "returns an empty string at EOF" do
        sio = create_sio_with_content("data")
        sio.read # consume all
        expect(sio.read).to eq("")
      end

      it "returns remaining bytes after a partial read" do
        sio = create_sio_with_content("abcdef")
        sio.read(3) # consume "abc"
        expect(sio.read).to eq("def")
      end
    end

    context "with length argument" do
      it "returns up to length bytes" do
        sio = create_sio_with_content("Hello, World!")
        expect(sio.read(5)).to eq("Hello")
      end

      it "returns fewer bytes when fewer remain" do
        sio = create_sio_with_content("Hi")
        expect(sio.read(10)).to eq("Hi")
      end

      it "returns nil at EOF" do
        sio = create_sio_with_content("data")
        sio.read # consume all
        expect(sio.read(5)).to be_nil
      end

      it "returns an empty string for read(0)" do
        sio = create_sio_with_content("data")
        expect(sio.read(0)).to eq("")
      end
    end

    context "with length and outbuf arguments" do
      it "writes read bytes into outbuf and returns the data" do
        sio = create_sio_with_content("Hello, World!")
        outbuf = String.new
        result = sio.read(5, outbuf)
        expect(result).to eq("Hello")
        expect(outbuf).to eq("Hello")
      end

      it "replaces outbuf content on each call" do
        sio = create_sio_with_content("abcdef")
        outbuf = String.new("old content")
        sio.read(3, outbuf)
        expect(outbuf).to eq("abc")
      end
    end
  end

  describe "#rewind" do
    it "resets position to 0 and returns 0" do
      sio = create_sio_with_content("Hello")
      sio.read(3)
      result = sio.rewind
      expect(result).to eq(0)
      expect(sio.pos).to eq(0)
    end

    it "allows re-reading from the beginning" do
      sio = create_sio_with_content("Hello")
      first_read = sio.read
      sio.rewind
      second_read = sio.read
      expect(second_read).to eq(first_read)
    end
  end

  describe "#size / #length" do
    it "returns the total number of bytes in the buffer" do
      sio = create_sio_with_content("Hello, World!")
      expect(sio.size).to eq(13)
    end

    it "returns the same value regardless of read position" do
      sio = create_sio_with_content("abcdef")
      sio.read(3)
      expect(sio.size).to eq(6)
    end

    it "is aliased as length" do
      sio = create_sio_with_content("test")
      expect(sio.length).to eq(sio.size)
    end
  end

  describe "#string" do
    it "returns the entire buffer contents" do
      sio = create_sio_with_content("Hello, World!")
      expect(sio.string).to eq("Hello, World!")
    end

    it "does not modify the read position" do
      sio = create_sio_with_content("abcdef")
      sio.read(3)
      sio.string
      expect(sio.pos).to eq(3)
    end

    it "returns a frozen String" do
      sio = create_sio_with_content("test")
      expect(sio.string).to be_frozen
    end
  end

  describe "#eof?" do
    it "returns false when not at end" do
      sio = create_sio_with_content("data")
      expect(sio.eof?).to be false
    end

    it "returns true when at end" do
      sio = create_sio_with_content("data")
      sio.read
      expect(sio.eof?).to be true
    end

    it "returns true for an empty buffer" do
      sio = AwsCrt::Http::SharableStringIO.new
      expect(sio.eof?).to be true
    end
  end

  describe "#pos / #tell" do
    it "returns 0 initially" do
      sio = create_sio_with_content("data")
      expect(sio.pos).to eq(0)
      expect(sio.tell).to eq(0)
    end

    it "advances after read" do
      sio = create_sio_with_content("Hello")
      sio.read(3)
      expect(sio.pos).to eq(3)
      expect(sio.tell).to eq(3)
    end
  end

  describe "#pos=" do
    it "sets the read position" do
      sio = create_sio_with_content("Hello, World!")
      sio.pos = 7
      expect(sio.read).to eq("World!")
    end

    it "clamps to buffer size when set beyond end" do
      sio = create_sio_with_content("Hi")
      sio.pos = 100
      expect(sio.pos).to eq(2)
    end

    it "allows setting to 0" do
      sio = create_sio_with_content("data")
      sio.read
      sio.pos = 0
      expect(sio.pos).to eq(0)
    end
  end

  describe "encoding" do
    it "returns ASCII-8BIT encoded strings from read" do
      sio = create_sio_with_content("Hello")
      result = sio.read
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "returns ASCII-8BIT encoded strings from read with length" do
      sio = create_sio_with_content("Hello")
      result = sio.read(3)
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "returns ASCII-8BIT encoded string from string" do
      sio = create_sio_with_content("Hello")
      expect(sio.string.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "handles binary data correctly" do
      binary_content = (0..255).map(&:chr).join
      sio = create_sio_with_content(binary_content)
      expect(sio.read).to eq(binary_content.b)
      expect(sio.size).to eq(256)
    end
  end

  describe "frozen state" do
    it "is frozen" do
      sio = create_sio_with_content("test")
      expect(sio).to be_frozen
    end

    it "is frozen even when created empty" do
      sio = AwsCrt::Http::SharableStringIO.new
      expect(sio).to be_frozen
    end
  end

  describe "Ractor.shareable?" do
    it "returns true" do
      sio = create_sio_with_content("test")
      expect(Ractor.shareable?(sio)).to be true
    end

    it "returns true for empty instance" do
      sio = AwsCrt::Http::SharableStringIO.new
      expect(Ractor.shareable?(sio)).to be true
    end
  end

  describe "absence of write methods" do
    it "does not respond to write" do
      sio = create_sio_with_content("test")
      expect(sio).not_to respond_to(:write)
    end

    it "does not respond to <<" do
      sio = create_sio_with_content("test")
      expect(sio).not_to respond_to(:<<)
    end

    it "does not respond to puts" do
      sio = create_sio_with_content("test")
      expect(sio).not_to respond_to(:puts)
    end

    it "does not respond to print" do
      sio = create_sio_with_content("test")
      expect(sio).not_to respond_to(:print)
    end
  end

  describe "error cases" do
    describe "negative pos=" do
      it "raises Errno::EINVAL" do
        sio = create_sio_with_content("test")
        expect { sio.pos = -1 }.to raise_error(Errno::EINVAL)
      end
    end

    describe "#closed?" do
      it "returns true" do
        sio = create_sio_with_content("test")
        expect(sio.closed?).to be true
      end

      it "returns true for empty instance" do
        sio = AwsCrt::Http::SharableStringIO.new
        expect(sio.closed?).to be true
      end
    end
  end

  describe "#write_to_file" do
    it "writes the entire buffer to a file" do
      sio = create_sio_with_content("Hello, file!")
      path = File.join(Dir.tmpdir, "sio_write_test_#{$$}")
      begin
        bytes_written = sio.write_to_file(path)
        expect(bytes_written).to eq(12)
        expect(File.binread(path)).to eq("Hello, file!")
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    it "writes at a byte offset" do
      content = "ABCDEFGH"
      sio = create_sio_with_content(content)
      path = File.join(Dir.tmpdir, "sio_offset_test_#{$$}")
      begin
        # Pre-fill the file with zeros
        File.binwrite(path, "\x00" * 16)
        sio.write_to_file(path, offset: 4)
        result = File.binread(path)
        expect(result[4, 8]).to eq("ABCDEFGH")
        expect(result[0, 4]).to eq("\x00" * 4)
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    it "returns 0 for an empty buffer" do
      sio = AwsCrt::Http::SharableStringIO.new
      path = File.join(Dir.tmpdir, "sio_empty_test_#{$$}")
      begin
        expect(sio.write_to_file(path)).to eq(0)
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    it "raises ArgumentError for negative offset" do
      sio = create_sio_with_content("data")
      expect { sio.write_to_file("/tmp/x", offset: -1) }.to raise_error(ArgumentError)
    end
  end

  describe "#write_to_io" do
    it "writes the entire buffer to an IO object" do
      sio = create_sio_with_content("Hello, IO!")
      path = File.join(Dir.tmpdir, "sio_io_test_#{$$}")
      begin
        File.open(path, "wb") do |f|
          bytes_written = sio.write_to_io(f)
          expect(bytes_written).to eq(10)
        end
        expect(File.binread(path)).to eq("Hello, IO!")
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    it "writes at a byte offset in the IO" do
      sio = create_sio_with_content("DATA")
      path = File.join(Dir.tmpdir, "sio_io_offset_test_#{$$}")
      begin
        File.binwrite(path, "\x00" * 16)
        File.open(path, "r+b") do |f|
          sio.write_to_io(f, offset: 8)
        end
        result = File.binread(path)
        expect(result[8, 4]).to eq("DATA")
        expect(result[0, 8]).to eq("\x00" * 8)
      ensure
        File.delete(path) if File.exist?(path)
      end
    end

    it "falls back to Ruby write for non-fd IOs like StringIO" do
      sio = create_sio_with_content("fallback test")
      target = StringIO.new
      bytes_written = sio.write_to_io(target)
      expect(bytes_written).to eq(13)
      expect(target.string).to eq("fallback test")
    end

    it "returns 0 for an empty buffer" do
      sio = AwsCrt::Http::SharableStringIO.new
      target = StringIO.new
      expect(sio.write_to_io(target)).to eq(0)
    end

    it "raises ArgumentError for negative offset" do
      sio = create_sio_with_content("data")
      expect { sio.write_to_io($stdout, offset: -1) }.to raise_error(ArgumentError)
    end
  end
end
