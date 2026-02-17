# frozen_string_literal: true

# S3 concurrent I/O benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# Uses a fixed thread pool (concurrent-ruby) to measure throughput under
# concurrent load. This is NOT single-threaded like benchmark-ips — it
# exercises real I/O parallelism.
#
# ENV vars:
#   BENCH_S3_BUCKET      – S3 bucket name (default: "test-bucket-alexwoo-2")
#   BENCH_TOTAL_CALLS    – total number of API calls to make (default: 1000)
#   BENCH_THREADS        – thread pool size (default: 8)
#
# Usage:
#   bundle exec rake benchmark:http:s3_concurrent
#   bundle exec ruby benchmarks/http_s3_concurrent.rb

require "concurrent"
require "aws-sdk-s3"
require "aws_crt/http/plugin"

BUCKET      = ENV.fetch("BENCH_S3_BUCKET", "test-bucket-alexwoo-2")
TOTAL_CALLS = Integer(ENV.fetch("BENCH_TOTAL_CALLS", "1000"))
THREADS     = Integer(ENV.fetch("BENCH_THREADS", "8"))

SIZES = {
  "64KB" => 64 * 1024,
  "1MB" => 1024 * 1024
}.freeze

KEYS = SIZES.transform_values { |sz| "crt-http-benchmark-test_#{sz}" }.freeze
BODIES = SIZES.transform_values { |sz| "x" * sz }.freeze

# ---------------------------------------------------------------------------
# Setup
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
# Benchmark helper
# ---------------------------------------------------------------------------

def run_concurrent(label, total, threads, &block)
  pool = Concurrent::FixedThreadPool.new(threads)
  errors = Concurrent::AtomicFixnum.new(0)

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  total.times do
    pool.post do
      block.call
    rescue StandardError => e
      errors.increment
      warn "  [error] #{e.class}: #{e.message}" if errors.value <= 5
    end
  end

  pool.shutdown
  pool.wait_for_termination

  finish = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  elapsed = finish - start
  rps = total / elapsed

  puts format("  %<label>-40s %<elapsed>8.2fs  %<rps>8.1f calls/s  (%<errors>d errors)",
              label: label, elapsed: elapsed, rps: rps, errors: errors.value)
  { elapsed: elapsed, rps: rps, errors: errors.value }
end

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

default_client = Aws::S3::Client.new

Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::S3::Client.new

setup_s3_test_data(default_client)

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------

puts "S3 Concurrent Benchmark"
puts "  Threads: #{THREADS}  |  Total calls: #{TOTAL_CALLS}"
puts "=" * 72

SIZES.each_key do |size_label|
  key  = KEYS[size_label]
  body = BODIES[size_label]

  puts "\n--- put_object (#{size_label}) ---"

  run_concurrent("Net::HTTP", TOTAL_CALLS, THREADS) do
    default_client.put_object(bucket: BUCKET, key: key, body: body)
  end

  run_concurrent("CRT", TOTAL_CALLS, THREADS) do
    crt_client.put_object(bucket: BUCKET, key: key, body: body)
  end

  puts "\n--- get_object (#{size_label}) ---"

  run_concurrent("Net::HTTP", TOTAL_CALLS, THREADS) do
    default_client.get_object(bucket: BUCKET, key: key)
  end

  run_concurrent("CRT", TOTAL_CALLS, THREADS) do
    crt_client.get_object(bucket: BUCKET, key: key)
  end
end

puts "\nDone."
