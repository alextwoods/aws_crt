# frozen_string_literal: true

# DynamoDB get/put benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# ENV vars:
#   BENCH_DYNAMODB_TABLE – table name
#     (default: "Bench_SDK_ruby_lambdaArchitecture-x86_64_lambdaMem_8tqkhbdddcw")
#
# Table schema: partition key "id" (String), no sort key.
#
# Usage:
#   bundle exec ruby benchmarks/http_dynamodb.rb

require "benchmark/ips"
require "aws-sdk-dynamodb"
require "aws_crt"
require "securerandom"

TABLE = ENV.fetch(
  "BENCH_DYNAMODB_TABLE",
  "Bench_SDK_ruby_lambdaArchitecture-x86_64_lambdaMem_8tqkhbdddcw"
)

# Pre-generate 1 000 test items (id "0".."999", random attr1)
TEST_ITEMS = (0...1000).map do |i|
  {
    "id" => i.to_s,
    "attr1" => SecureRandom.alphanumeric(100)
  }
end.freeze

def run_benchmarks(label, client)
  puts "\n#{"=" * 60}"
  puts "  #{label}"
  puts "=" * 60

  # --- PutItem ---
  puts "\n--- PutItem (1 000 items, round-robin) ---"
  idx = 0
  Benchmark.ips do |x|
    x.report("put_item") do
      item = TEST_ITEMS[idx % TEST_ITEMS.size]
      client.put_item(table_name: TABLE, item: item)
      idx += 1
    end
    x.compare!
  end

  # --- GetItem ---
  puts "\n--- GetItem (1 000 items, round-robin) ---"
  idx = 0
  Benchmark.ips do |x|
    x.report("get_item") do
      key = { "id" => (idx % TEST_ITEMS.size).to_s }
      client.get_item(table_name: TABLE, key: key)
      idx += 1
    end
    x.compare!
  end
end

# --- Default SDK (Net::HTTP) ---
default_client = Aws::DynamoDB::Client.new
run_benchmarks("DynamoDB — Net::HTTP (default SDK)", default_client)

# --- CRT HTTP plugin ---
Aws::DynamoDB::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::DynamoDB::Client.new
run_benchmarks("DynamoDB — CRT HTTP plugin", crt_client)
