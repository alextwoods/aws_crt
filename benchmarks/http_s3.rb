# frozen_string_literal: true

# S3 get/put benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# Each operation + payload size gets its own Benchmark.ips block so that
# `compare!` shows the meaningful Net::HTTP vs CRT comparison.
#
# ENV vars:
#   BENCH_S3_BUCKET  – S3 bucket name (default: "test-bucket-alexwoo-2")
#
# Usage:
#   bundle exec rake benchmark:http:s3
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

# ---------------------------------------------------------------------------
# Setup — ensure test objects exist in S3
# ---------------------------------------------------------------------------

def setup_s3_test_data(client)
  puts "Setting up S3 test data..."
  SIZES.each_key do |size_label|
    key  = KEYS[size_label]
    body = BODIES[size_label]
    client.put_object(bucket: BUCKET, key: key, body: body)
    puts "  ✓ #{key} (#{size_label})"
  end
  puts "Setup complete.\n\n"
end

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

default_client = Aws::S3::Client.new

Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::S3::Client.new

# Seed test data using the default client
setup_s3_test_data(default_client)

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

SIZES.each_key do |size_label|
  key  = KEYS[size_label]
  body = BODIES[size_label]

  puts "\n--- PutObject #{size_label} ---"
  Benchmark.ips do |x|
    x.report("Net::HTTP put_object (#{size_label})") do
      default_client.put_object(bucket: BUCKET, key: key, body: body)
    end

    x.report("CRT put_object (#{size_label})") do
      crt_client.put_object(bucket: BUCKET, key: key, body: body)
    end

    x.compare!
  end

  puts "\n--- GetObject #{size_label} ---"
  Benchmark.ips do |x|
    x.report("Net::HTTP get_object (#{size_label})") do
      default_client.get_object(bucket: BUCKET, key: key)
    end

    x.report("CRT get_object (#{size_label})") do
      crt_client.get_object(bucket: BUCKET, key: key)
    end

    x.compare!
  end
end
