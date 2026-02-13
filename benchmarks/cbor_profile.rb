# frozen_string_literal: true

require "stackprof"
require "aws_crt"

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

encoded = AwsCrt::Cbor::Encoder.new.add(LARGE).bytes

puts "=== Encode Profile ==="
result = StackProf.run(mode: :wall, interval: 100, raw: true) do
  10_000.times { AwsCrt::Cbor::Encoder.new.add(LARGE).bytes }
end
StackProf::Report.new(result).print_text

puts "\n=== Decode Profile ==="
result = StackProf.run(mode: :wall, interval: 100, raw: true) do
  10_000.times { AwsCrt::Cbor::Decoder.new(encoded).decode }
end
StackProf::Report.new(result).print_text
