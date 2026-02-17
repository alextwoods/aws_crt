# frozen_string_literal: true

# DynamoDB concurrent I/O benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# Uses a fixed thread pool (concurrent-ruby) to measure throughput under
# concurrent load. This is NOT single-threaded like benchmark-ips — it
# exercises real I/O parallelism.
#
# ENV vars:
#   BENCH_DYNAMODB_TABLE – table name
#     (default: "Bench_SDK_ruby_lambdaArchitecture-x86_64_lambdaMem_8tqkhbdddcw")
#   BENCH_TOTAL_CALLS    – total number of API calls to make (default: 1000)
#   BENCH_THREADS        – thread pool size (default: 8)
#
# Table schema: partition key "id" (String), no sort key.
#
# Usage:
#   bundle exec rake benchmark:http:dynamodb_concurrent
#   bundle exec ruby benchmarks/http_dynamodb_concurrent.rb

require "concurrent"
require "aws-sdk-dynamodb"
require "aws_crt/http/plugin"
require "securerandom"

TABLE = ENV.fetch(
  "BENCH_DYNAMODB_TABLE",
  "Bench_SDK_ruby_lambdaArchitecture-x86_64_lambdaMem_8tqkhbdddcw"
)
TOTAL_CALLS = Integer(ENV.fetch("BENCH_TOTAL_CALLS", "1000"))
THREADS     = Integer(ENV.fetch("BENCH_THREADS", "8"))

# Pre-generate 1 000 test items (id "0".."999", random attr1)
TEST_ITEMS = (0...1000).map do |i|
  {
    "id" => i.to_s,
    "attr1" => SecureRandom.alphanumeric(100)
  }
end.freeze

# ---------------------------------------------------------------------------
# Setup — ensure all test items exist in DynamoDB
# ---------------------------------------------------------------------------

def setup_dynamodb_test_data(client)
  puts "Setting up DynamoDB test data (#{TEST_ITEMS.size} items)..."
  TEST_ITEMS.each_slice(25) do |batch|
    client.batch_write_item(
      request_items: {
        TABLE => batch.map { |item| { put_request: { item: item } } }
      }
    )
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

default_client = Aws::DynamoDB::Client.new

Aws::DynamoDB::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::DynamoDB::Client.new(max_connections: [25, THREADS + 5].min)

setup_dynamodb_test_data(default_client)

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------

puts "DynamoDB Concurrent Benchmark"
puts "  Threads: #{THREADS}  |  Total calls: #{TOTAL_CALLS}"
puts "=" * 72

idx = Concurrent::AtomicFixnum.new(0)

puts "\n--- put_item ---"

run_concurrent("Net::HTTP", TOTAL_CALLS, THREADS) do
  i = idx.increment - 1
  item = TEST_ITEMS[i % TEST_ITEMS.size]
  default_client.put_item(table_name: TABLE, item: item)
end

idx = Concurrent::AtomicFixnum.new(0)

run_concurrent("CRT", TOTAL_CALLS, THREADS) do
  i = idx.increment - 1
  item = TEST_ITEMS[i % TEST_ITEMS.size]
  crt_client.put_item(table_name: TABLE, item: item)
end

puts "\n--- get_item ---"

idx = Concurrent::AtomicFixnum.new(0)

run_concurrent("Net::HTTP", TOTAL_CALLS, THREADS) do
  i = idx.increment - 1
  key = { "id" => (i % TEST_ITEMS.size).to_s }
  default_client.get_item(table_name: TABLE, key: key)
end

idx = Concurrent::AtomicFixnum.new(0)

run_concurrent("CRT", TOTAL_CALLS, THREADS) do
  i = idx.increment - 1
  key = { "id" => (i % TEST_ITEMS.size).to_s }
  crt_client.get_item(table_name: TABLE, key: key)
end

puts "\nDone."
