# frozen_string_literal: true

require "benchmark/ips"
require "zlib"
require "aws_crt"
require "aws-crt"

SMALL  = "Hello world"
MEDIUM = "x" * 1024          # 1 KB
LARGE  = "x" * (1024 * 1024) # 1 MB

SIZES = { "small (11 B)" => SMALL, "medium (1 KB)" => MEDIUM, "large (1 MB)" => LARGE }.freeze

puts "=== CRC32 ==="
SIZES.each do |label, data|
  puts "\n--- #{label} ---"
  Benchmark.ips do |x|
    x.report("Zlib.crc32")                { Zlib.crc32(data) }
    x.report("Aws::Crt::Checksums.crc32") { Aws::Crt::Checksums.crc32(data) }
    x.report("AwsCrt::Checksums.crc32")   { AwsCrt::Checksums.crc32(data) }
    x.compare!
  end
end

puts "\n=== CRC32C ==="
SIZES.each do |label, data|
  puts "\n--- #{label} ---"
  Benchmark.ips do |x|
    x.report("Aws::Crt::Checksums.crc32c") { Aws::Crt::Checksums.crc32c(data) }
    x.report("AwsCrt::Checksums.crc32c")   { AwsCrt::Checksums.crc32c(data) }
    x.compare!
  end
end

puts "\n=== CRC64-NVME ==="
SIZES.each do |label, data|
  puts "\n--- #{label} ---"
  Benchmark.ips do |x|
    x.report("Aws::Crt::Checksums.crc64nvme") { Aws::Crt::Checksums.crc64nvme(data) }
    x.report("AwsCrt::Checksums.crc64nvme")   { AwsCrt::Checksums.crc64nvme(data) }
    x.compare!
  end
end
