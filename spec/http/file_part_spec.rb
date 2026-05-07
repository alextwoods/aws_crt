# frozen_string_literal: true

# Unit tests for AwsCrt::Http::FilePart.
#
# Tests the read-only, Ractor-safe IO interface backed by a native
# Rust file reader. FilePart provides an IO-like interface to a byte
# range within a file on disk.

require "tmpdir"
require "stringio"

RSpec.describe AwsCrt::Http::FilePart do
  let(:tmpdir) { Dir.mktmpdir("file_part_test") }
  let(:test_file) { File.join(tmpdir, "test_data.bin") }
  let(:test_content) { "Hello, World! This is test content for FilePart." }

  before do
    File.binwrite(test_file, test_content)
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  describe ".new" do
    it "creates a FilePart with source, offset, and size" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp).to be_a(AwsCrt::Http::FilePart)
    end

    it "is frozen upon creation" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp).to be_frozen
    end

    it "is Ractor-shareable" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(Ractor.shareable?(fp)).to be true
    end

    it "raises ArgumentError for negative offset" do
      expect do
        AwsCrt::Http::FilePart.new(source: test_file, offset: -1, size: 5)
      end.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for negative size" do
      expect do
        AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: -1)
      end.to raise_error(ArgumentError)
    end
  end

  describe "#source" do
    it "returns the source file path" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp.source).to eq(test_file)
    end
  end

  describe "#offset" do
    it "returns the byte offset" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 7, size: 5)
      expect(fp.offset).to eq(7)
    end
  end

  describe "#size / #length" do
    it "returns the declared size" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect(fp.size).to eq(13)
    end

    it "is aliased as length" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect(fp.length).to eq(fp.size)
    end
  end

  describe "#read" do
    context "with no arguments" do
      it "returns all bytes in the part" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
        expect(fp.read).to eq("Hello, World!")
      end

      it "returns bytes from the specified offset" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 7, size: 6)
        expect(fp.read).to eq("World!")
      end

      it "returns an empty string at EOF" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
        fp.read # consume all
        expect(fp.read).to eq("")
      end

      it "returns remaining bytes after a partial read" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
        fp.read(7) # consume "Hello, "
        expect(fp.read).to eq("World!")
      end
    end

    context "with length argument" do
      it "returns up to length bytes" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
        expect(fp.read(5)).to eq("Hello")
      end

      it "returns fewer bytes when fewer remain" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
        expect(fp.read(10)).to eq("Hello")
      end

      it "returns nil at EOF" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
        fp.read # consume all
        expect(fp.read(5)).to be_nil
      end

      it "returns an empty string for read(0)" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
        expect(fp.read(0)).to eq("")
      end
    end

    context "with length and outbuf arguments" do
      it "writes read bytes into outbuf and returns the data" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
        outbuf = String.new
        result = fp.read(5, outbuf)
        expect(result).to eq("Hello")
        expect(outbuf).to eq("Hello")
      end

      it "replaces outbuf content on each call" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
        outbuf = String.new("old content")
        fp.read(5, outbuf)
        expect(outbuf).to eq("Hello")
      end
    end

    context "encoding" do
      it "returns ASCII-8BIT encoded strings" do
        fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
        result = fp.read
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end
    end

    context "with binary data" do
      it "handles binary content correctly" do
        binary_content = (0..255).map(&:chr).join
        binary_file = File.join(tmpdir, "binary.bin")
        File.binwrite(binary_file, binary_content)

        fp = AwsCrt::Http::FilePart.new(source: binary_file, offset: 0, size: 256)
        expect(fp.read).to eq(binary_content.b)
        expect(fp.size).to eq(256)
      end

      it "reads a portion of binary data" do
        binary_content = (0..255).map(&:chr).join
        binary_file = File.join(tmpdir, "binary.bin")
        File.binwrite(binary_file, binary_content)

        fp = AwsCrt::Http::FilePart.new(source: binary_file, offset: 100, size: 50)
        expected = binary_content.b[100, 50]
        expect(fp.read).to eq(expected)
      end
    end
  end

  describe "#rewind" do
    it "resets position to 0 and returns 0" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.read(5)
      result = fp.rewind
      expect(result).to eq(0)
      expect(fp.pos).to eq(0)
    end

    it "allows re-reading from the beginning" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      first_read = fp.read
      fp.rewind
      second_read = fp.read
      expect(second_read).to eq(first_read)
    end
  end

  describe "#eof?" do
    it "returns false when not at end" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect(fp.eof?).to be false
    end

    it "returns true when at end" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.read
      expect(fp.eof?).to be true
    end

    it "returns true for a zero-size part" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 0)
      expect(fp.eof?).to be true
    end
  end

  describe "#pos / #tell" do
    it "returns 0 initially" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect(fp.pos).to eq(0)
      expect(fp.tell).to eq(0)
    end

    it "advances after read" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.read(5)
      expect(fp.pos).to eq(5)
      expect(fp.tell).to eq(5)
    end
  end

  describe "#pos=" do
    it "sets the read position" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.pos = 7
      expect(fp.read).to eq("World!")
    end

    it "clamps to size when set beyond end" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      fp.pos = 100
      expect(fp.pos).to eq(5)
    end

    it "allows setting to 0" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.read
      fp.pos = 0
      expect(fp.pos).to eq(0)
    end

    it "raises Errno::EINVAL for negative values" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect { fp.pos = -1 }.to raise_error(Errno::EINVAL)
    end
  end

  describe "#string" do
    it "returns the entire part contents" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      expect(fp.string).to eq("Hello, World!")
    end

    it "returns a frozen String" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp.string).to be_frozen
    end

    it "does not modify the read position" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)
      fp.read(5)
      fp.string
      expect(fp.pos).to eq(5)
    end
  end

  describe "#closed?" do
    it "returns false" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp.closed?).to be false
    end
  end

  describe "#close" do
    it "is a no-op and returns nil" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 5)
      expect(fp.close).to be_nil
    end
  end

  describe "error cases" do
    it "raises IOError when the file does not exist" do
      fp = AwsCrt::Http::FilePart.new(source: "/nonexistent/path.bin", offset: 0, size: 10)
      expect { fp.read }.to raise_error(IOError, /FilePart read failed/)
    end
  end

  describe "Ractor integration" do
    it "can be passed to a Ractor and read there" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)

      result = Ractor.new(fp, &:read).value

      expect(result).to eq("Hello, World!")
    end

    it "can be created in a Ractor and read in the main Ractor" do
      path = test_file

      fp = Ractor.new(path) do |p|
        AwsCrt::Http::FilePart.new(source: p, offset: 7, size: 6)
      end.value

      expect(fp.read).to eq("World!")
    end
  end

  describe "compatibility with IO consumers" do
    it "works with checksum computation (read + rewind pattern)" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)

      # Simulate checksum computation: read all, compute, rewind
      data = fp.read
      checksum = AwsCrt::Checksums.crc32(data)
      fp.rewind

      # Verify we can read again
      expect(fp.read).to eq("Hello, World!")
      expect(checksum).to be_a(Integer)
    end

    it "works with chunked reading pattern" do
      fp = AwsCrt::Http::FilePart.new(source: test_file, offset: 0, size: 13)

      chunks = []
      while (chunk = fp.read(4))
        chunks << chunk
      end

      expect(chunks.join).to eq("Hello, World!")
    end
  end
end
