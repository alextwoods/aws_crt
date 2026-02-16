# frozen_string_literal: true

# S3 get/put benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# ENV vars:
#   BENCH_S3_BUCKET  – S3 bucket name (default: "test-bucket-alexwoo-2")
#
# Usage:
#   bundle exec ruby benchmarks/http_s3.rb

require "benchmark/ips"
require "aws-sdk-s3"
require "aws_crt/http/plugin"

BUCKET = ENV.fetch("BENCH_S3_BUCKET", "test-bucket-alexwoo-2")

SIZES = {
  "64KB" => 64 * 1024,
  "1MB" => 1024 * 1024
}.freeze

KEYS = SIZES.transform_values { |sz| "crt-http-benchmark-test_#{sz}" }.freeze
BODIES = SIZES.transform_values { |sz| "x" * sz }.freeze

def run_benchmarks(label, client)
  puts "\n#{"=" * 60}"
  puts "  #{label}"
  puts "=" * 60

  SIZES.each_key do |size_label|
    key  = KEYS[size_label]
    body = BODIES[size_label]

    puts "\n--- PutObject #{size_label} ---"
    Benchmark.ips do |x|
      x.report("put_object (#{size_label})") do
        client.put_object(bucket: BUCKET, key: key, body: body)
      end
      x.compare!
    end

    puts "\n--- GetObject #{size_label} ---"
    Benchmark.ips do |x|
      x.report("get_object (#{size_label})") do
        client.get_object(bucket: BUCKET, key: key)
      end
      x.compare!
    end
  end
end

# --- Default SDK (Net::HTTP) ---
default_client = Aws::S3::Client.new
run_benchmarks("S3 — Net::HTTP (default SDK)", default_client)

# --- CRT HTTP plugin ---
Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::S3::Client.new
run_benchmarks("S3 — CRT HTTP plugin", crt_client)
