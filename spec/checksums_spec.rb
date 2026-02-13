# frozen_string_literal: true

require "base64"

ZERO_CHAR = [0].pack("C*")
INT_MAX = (2**32) - 1

def int32_to_base64(num)
  Base64.encode64([num].pack("N"))
end

RSpec.describe AwsCrtS3Client::Checksums do
  describe ".crc32" do
    [
      { str: "", expected: "AAAAAA==\n" },
      { str: "abc", expected: "NSRBwg==\n" },
      { str: "Hello world", expected: "i9aeUg==\n" }
    ].each do |test_case|
      it "produces the correct checksum for '#{test_case[:str]}'" do
        checksum = int32_to_base64(described_class.crc32(test_case[:str]))
        expect(checksum).to eq(test_case[:expected])
      end
    end

    it "defaults previous to 0 when not provided" do
      expect(described_class.crc32("abc")).to eq(described_class.crc32("abc", nil))
    end

    it "works with zeros in one shot" do
      output = described_class.crc32(ZERO_CHAR * 32)
      expect(output).to eq(0x190A55AD)
    end

    it "works with zeros iterated" do
      output = 0
      32.times do
        output = described_class.crc32(ZERO_CHAR, output)
      end
      expect(output).to eq(0x190A55AD)
    end

    it "works with values in one shot" do
      buf = (0...32).to_a.pack("C*")
      output = described_class.crc32(buf)
      expect(output).to eq(0x91267E8A)
    end

    it "works with values iterated" do
      output = 0
      32.times do |i|
        output = described_class.crc32([i].pack("C*"), output)
      end
      expect(output).to eq(0x91267E8A)
    end

    it "works with a large buffer" do
      output = described_class.crc32(ZERO_CHAR * 25 * (2**20))
      expect(output).to eq(0x72103906)
    end

    it "works with a huge buffer" do
      output = described_class.crc32(ZERO_CHAR * (INT_MAX + 5))
      expect(output).to eq(0xc622f71d)
    rescue NoMemoryError, RangeError
      skip "Unable to allocate memory for crc32 huge buffer test"
    end
  end

  describe ".crc32c" do
    [
      { str: "", expected: "AAAAAA==\n" },
      { str: "abc", expected: "Nks/tw==\n" },
      { str: "Hello world", expected: "crUfeA==\n" }
    ].each do |test_case|
      it "produces the correct checksum for '#{test_case[:str]}'" do
        checksum = int32_to_base64(described_class.crc32c(test_case[:str]))
        expect(checksum).to eq(test_case[:expected])
      end
    end

    it "defaults previous to 0 when not provided" do
      expect(described_class.crc32c("abc")).to eq(described_class.crc32c("abc", nil))
    end

    it "works with zeros in one shot" do
      output = described_class.crc32c(ZERO_CHAR * 32)
      expect(output).to eq(0x8A9136AA)
    end

    it "works with zeros iterated" do
      output = 0
      32.times do
        output = described_class.crc32c(ZERO_CHAR, output)
      end
      expect(output).to eq(0x8A9136AA)
    end

    it "works with values in one shot" do
      buf = (0...32).to_a.pack("C*")
      output = described_class.crc32c(buf)
      expect(output).to eq(0x46DD794E)
    end

    it "works with values iterated" do
      output = 0
      32.times do |i|
        output = described_class.crc32c([i].pack("C*"), output)
      end
      expect(output).to eq(0x46DD794E)
    end

    it "works with a large buffer" do
      output = described_class.crc32c(ZERO_CHAR * 25 * (2**20))
      expect(output).to eq(0xfb5b991d)
    end

    it "works with a huge buffer" do
      output = described_class.crc32c(ZERO_CHAR * (INT_MAX + 5))
      expect(output).to eq(0x572a7c8a)
    rescue NoMemoryError, RangeError
      skip "Unable to allocate memory for crc32c huge buffer test"
    end
  end

  describe ".crc64nvme" do
    it "defaults previous to 0 when not provided" do
      expect(described_class.crc64nvme("abc")).to eq(described_class.crc64nvme("abc", nil))
    end

    it "works with zeros in one shot" do
      output = described_class.crc64nvme(ZERO_CHAR * 32)
      expect(output).to eq(0xCF3473434D4ECF3B)
    end

    it "works with zeros iterated" do
      output = 0
      32.times do
        output = described_class.crc64nvme(ZERO_CHAR, output)
      end
      expect(output).to eq(0xCF3473434D4ECF3B)
    end

    it "works with values in one shot" do
      buf = (0...32).to_a.pack("C*")
      output = described_class.crc64nvme(buf)
      expect(output).to eq(0xB9D9D4A8492CBD7F)
    end

    it "works with a large buffer" do
      output = described_class.crc64nvme(ZERO_CHAR * 25 * (2**20))
      expect(output).to eq(0x5B6F5045463CA45E)
    end

    it "works with a huge buffer" do
      output = described_class.crc64nvme(ZERO_CHAR * (INT_MAX + 5))
      expect(output).to eq(0x2645C28052B1FBB0)
    rescue NoMemoryError, RangeError
      skip "Unable to allocate memory for crc64nvme huge buffer test"
    end
  end
end
