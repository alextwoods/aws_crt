# frozen_string_literal: true

# DynamoDB get/put benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# PutItem and GetItem each get their own Benchmark.ips block so that
# `compare!` shows the meaningful Net::HTTP vs CRT comparison.
#
# ENV vars:
#   BENCH_DYNAMODB_TABLE – table name
#     (default: "Bench_SDK_ruby_lambdaArchitecture-x86_64_lambdaMem_8tqkhbdddcw")
#
# Table schema: partition key "id" (String), no sort key.
#
# Usage:
#   bundle exec rake benchmark:http:dynamodb
#   bundle exec ruby benchmarks/http_dynamodb.rb

require "benchmark/ips"
require "aws-sdk-dynamodb"
require "aws_crt/http/plugin"
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
# Clients
# ---------------------------------------------------------------------------

default_client = Aws::DynamoDB::Client.new

Aws::DynamoDB::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::DynamoDB::Client.new

# Seed test data using the default client
setup_dynamodb_test_data(default_client)

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

puts "\n--- PutItem ---"
put_idx_default = 0
put_idx_crt = 0

Benchmark.ips do |x|
  x.report("Net::HTTP put_item") do
    item = TEST_ITEMS[put_idx_default % TEST_ITEMS.size]
    default_client.put_item(table_name: TABLE, item: item)
    put_idx_default += 1
  end

  x.report("CRT put_item") do
    item = TEST_ITEMS[put_idx_crt % TEST_ITEMS.size]
    crt_client.put_item(table_name: TABLE, item: item)
    put_idx_crt += 1
  end

  x.compare!
end

puts "\n--- GetItem ---"
get_idx_default = 0
get_idx_crt = 0

Benchmark.ips do |x|
  x.report("Net::HTTP get_item") do
    key = { "id" => (get_idx_default % TEST_ITEMS.size).to_s }
    default_client.get_item(table_name: TABLE, key: key)
    get_idx_default += 1
  end

  x.report("CRT get_item") do
    key = { "id" => (get_idx_crt % TEST_ITEMS.size).to_s }
    crt_client.get_item(table_name: TABLE, key: key)
    get_idx_crt += 1
  end

  x.compare!
end
