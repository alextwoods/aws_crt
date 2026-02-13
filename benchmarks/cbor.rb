# frozen_string_literal: true

require "benchmark/ips"
require "json"
require "aws_crt"
require "aws-sdk-core"
require "aws-sdk-core/cbor"
require "cbor"

# ---------------------------------------------------------------------------
# Test data
# ---------------------------------------------------------------------------

SMALL = { "id" => 1, "status" => 200, "count" => 42 }.freeze

MEDIUM = (0...50).to_h { |i| ["key_#{i}", "value_#{i}" * 5] }.freeze

LARGE = {
  "metadata" => { "version" => 3, "region" => "us-east-1", "timestamp" => 1_700_000_000 },
  "items" => (0...100).map do |i|
    {
      "id" => i,
      "name" => "item_#{i}",
      "tags" => %w[alpha bravo charlie],
      "active" => i.even?,
      "score" => i * 1.5,
      "nested" => { "a" => i, "b" => "x" * 20 }
    }
  end,
  "summary" => "x" * 1024
}.freeze

PAYLOADS = {
  "small (3-key int map)" => SMALL,
  "medium (50-key string map)" => MEDIUM,
  "large (nested mixed map)" => LARGE
}.freeze

# Pre-encode for decode benchmarks
ENCODED = PAYLOADS.transform_values do |data|
  AwsCrt::Cbor::Encoder.new.add(data).bytes
end.freeze

JSON_ENCODED = PAYLOADS.transform_values do |data|
  JSON.dump(data)
end.freeze

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

puts "=== CBOR Encode ==="
PAYLOADS.each do |label, data|
  puts "\n--- #{label} ---"
  Benchmark.ips(quiet: true) do |x|
    x.report("AwsCrt::Cbor.encode (Rust)") do
      AwsCrt::Cbor.encode(data)
    end
    x.report("AwsCrt::Cbor::Encoder (Rust)") do
      AwsCrt::Cbor::Encoder.new.add(data).bytes
    end
    x.report("Aws::Cbor (pure Ruby)") do
      Aws::Cbor::Encoder.new.add(data).bytes
    end
    x.report("CBOR gem (C ext)") do
      data.to_cbor
    end
    x.report("JSON (stdlib)") do
      JSON.dump(data)
    end
    x.compare!
  end
end

# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

puts "\n=== CBOR Decode ==="
PAYLOADS.each_key do |label|
  encoded = ENCODED[label]
  json_encoded = JSON_ENCODED[label]
  puts "\n--- #{label} ---"
  Benchmark.ips(quiet: true) do |x|
    x.report("AwsCrt::Cbor.decode (Rust)") do
      AwsCrt::Cbor.decode(encoded)
    end
    x.report("AwsCrt::Cbor::Decoder (Rust)") do
      AwsCrt::Cbor::Decoder.new(encoded).decode
    end
    x.report("Aws::Cbor (pure Ruby)") do
      Aws::Cbor::Decoder.new(encoded).decode
    end
    x.report("CBOR gem (C ext)") do
      CBOR.decode(encoded)
    end
    x.report("JSON (stdlib)") do
      JSON.parse(json_encoded)
    end
    x.compare!
  end
end
