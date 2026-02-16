# frozen_string_literal: true

# CRT HTTP client vs Net::HTTP benchmark.
#
# Starts a local TestServer to eliminate network variability, then
# compares AwsCrt::Http::ConnectionPool against Net::HTTP for:
#   - Latency:    time per request for 1 KB and 1 MB responses
#   - Throughput:  requests per second with connection pooling
#   - Memory:      RSS delta after 1 000 requests
#
# Usage:
#   bundle exec ruby benchmarks/http.rb

require "benchmark/ips"
require "net/http"
require "aws_crt"
require_relative "../spec/support/test_server"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rss_kb
  # Works on Linux and macOS
  `ps -o rss= -p #{Process.pid}`.strip.to_i
end

def net_http_get(uri, path)
  Net::HTTP.start(uri.host, uri.port) { |http| http.get(path) }
end

def net_http_persistent_get(http, path)
  http.get(path)
end

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------

server = TestServer.start
at_exit { server.stop }

endpoint = server.endpoint # e.g. "http://127.0.0.1:<port>"
uri      = URI.parse(endpoint)

PATH_1KB = "/?body_size=1024"
PATH_1MB = "/?body_size=#{1024 * 1024}".freeze
PATH_THROUGHPUT = "/?body_size=64"

# Create a CRT connection pool (reused across benchmarks)
crt_pool = AwsCrt::Http::ConnectionPool.new(endpoint,
                                            max_connections: 25,
                                            ssl_verify_peer: false)

host_header = [["Host", "127.0.0.1"]]

# Warm up both clients
crt_pool.request("GET", PATH_1KB, host_header)
net_http_get(uri, PATH_1KB)

# ---------------------------------------------------------------------------
# Latency — 1 KB response
# ---------------------------------------------------------------------------

puts "=== Latency: 1 KB response ==="
Benchmark.ips do |x|
  x.report("CRT  (1 KB)") do
    crt_pool.request("GET", PATH_1KB, host_header)
  end

  x.report("Net::HTTP (1 KB)") do
    net_http_get(uri, PATH_1KB)
  end

  x.compare!
end

# ---------------------------------------------------------------------------
# Latency — 1 MB response
# ---------------------------------------------------------------------------

puts "\n=== Latency: 1 MB response ==="
Benchmark.ips do |x|
  x.report("CRT  (1 MB)") do
    crt_pool.request("GET", PATH_1MB, host_header)
  end

  x.report("Net::HTTP (1 MB)") do
    net_http_get(uri, PATH_1MB)
  end

  x.compare!
end

# ---------------------------------------------------------------------------
# Throughput — connection pooling
# ---------------------------------------------------------------------------

puts "\n=== Throughput: connection pooling (64 B response) ==="
Benchmark.ips do |x|
  # CRT reuses connections via its built-in pool
  x.report("CRT  (pooled)") do
    crt_pool.request("GET", PATH_THROUGHPUT, host_header)
  end

  # Net::HTTP with keep-alive to approximate pooling
  persistent = Net::HTTP.new(uri.host, uri.port)
  persistent.start

  x.report("Net::HTTP (keep-alive)") do
    net_http_persistent_get(persistent, PATH_THROUGHPUT)
  end

  x.compare!

  persistent.finish
end

# ---------------------------------------------------------------------------
# Memory — RSS delta after 1 000 requests
# ---------------------------------------------------------------------------

puts "\n=== Memory: RSS delta after 1 000 requests ==="

MEMORY_ITERATIONS = 1_000

# Force GC before measuring baseline
GC.start
GC.compact if GC.respond_to?(:compact)

# --- CRT ---
rss_before = rss_kb
MEMORY_ITERATIONS.times { crt_pool.request("GET", PATH_1KB, host_header) }
GC.start
rss_after = rss_kb
puts "CRT          : +#{rss_after - rss_before} KB after #{MEMORY_ITERATIONS} requests"

# --- Net::HTTP ---
GC.start
GC.compact if GC.respond_to?(:compact)
rss_before = rss_kb
MEMORY_ITERATIONS.times { net_http_get(uri, PATH_1KB) }
GC.start
rss_after = rss_kb
puts "Net::HTTP    : +#{rss_after - rss_before} KB after #{MEMORY_ITERATIONS} requests"
