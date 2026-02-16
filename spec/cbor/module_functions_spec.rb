# frozen_string_literal: true

require "base64"
require "bigdecimal"
require "time"

RSpec.describe AwsCrt::Cbor do
  describe ".encode / .decode" do
    it "round-trips simple types" do
      [0, 1, -1, 24, 65_535, true, false, nil].each do |val|
        expect(described_class.decode(described_class.encode(val))).to eq(val)
      end
    end

    it "round-trips floats" do
      [1.1, -4.1, 1.0e+300].each do |val|
        expect(described_class.decode(described_class.encode(val))).to eq(val)
      end
    end

    it "round-trips NaN and Infinity" do
      expect(described_class.decode(described_class.encode(Float::NAN))).to be_nan
      expect(described_class.decode(described_class.encode(Float::INFINITY))).to eq(Float::INFINITY)
    end

    it "round-trips strings" do
      expect(described_class.decode(described_class.encode("hello"))).to eq("hello")
    end

    it "round-trips byte strings" do
      bin = "binary".encode(Encoding::BINARY)
      result = described_class.decode(described_class.encode(bin))
      expect(result).to eq(bin)
      expect(result.encoding).to eq(Encoding::BINARY)
    end

    it "round-trips arrays" do
      expect(described_class.decode(described_class.encode([1, [2, 3]]))).to eq([1, [2, 3]])
    end

    it "round-trips maps" do
      data = { "a" => 1, "b" => [2, 3] }
      expect(described_class.decode(described_class.encode(data))).to eq(data)
    end

    it "round-trips times" do
      time = Time.parse("2020-01-01 12:21:42Z")
      result = described_class.decode(described_class.encode(time))
      expect(result).to eq(time)
    end

    it "round-trips BigDecimals" do
      bd = BigDecimal("273.15")
      expect(described_class.decode(described_class.encode(bd))).to eq(bd)
    end

    it "round-trips large integers (BigNums)" do
      val = (2**64) + 1
      expect(described_class.decode(described_class.encode(val))).to eq(val)
    end

    it "produces identical bytes to the Encoder class" do
      data = { "id" => 1, "tags" => %w[a b], "active" => true }
      class_bytes = AwsCrt::Cbor::Encoder.new.add(data).bytes
      module_bytes = described_class.encode(data)
      expect(module_bytes).to eq(class_bytes)
    end

    it "raises ExtraBytesError on trailing data" do
      encoded = described_class.encode(1) + described_class.encode(2)
      expect { described_class.decode(encoded) }
        .to raise_error(AwsCrt::Cbor::ExtraBytesError)
    end

    it "raises TypeError on non-string decode input" do
      expect { described_class.decode(123) }.to raise_error(TypeError)
    end
  end
end
