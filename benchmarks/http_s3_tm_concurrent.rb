# frozen_string_literal: true

# S3 TransferManager multipart benchmark: Net::HTTP (default SDK) vs CRT HTTP plugin.
#
# Configures TransferManager with a concurrent-ruby executor so that
# multipart upload/download parts are transferred in parallel. Each
# benchmark iteration runs 5 sequential upload_file / download_file
# operations to measure sustained multipart throughput.
#
# ENV vars:
#   BENCH_S3_BUCKET   – S3 bucket name (default: "test-bucket-alexwoo-2")
#   BENCH_ITERATIONS  – number of sequential transfers per measurement (default: 5)
#   BENCH_THREADS     – thread pool size for the TM executor (default: 8)
#
# Usage:
#   bundle exec rake benchmark:http:s3_tm_concurrent
#   bundle exec ruby benchmarks/http_s3_tm_concurrent.rb

require "concurrent"
require "aws-sdk-s3"
require "aws_crt/http/plugin"
require "tmpdir"
require "fileutils"

BUCKET     = ENV.fetch("BENCH_S3_BUCKET", "test-bucket-alexwoo-2")
ITERATIONS = Integer(ENV.fetch("BENCH_ITERATIONS", "5"))
THREADS    = Integer(ENV.fetch("BENCH_THREADS", "8"))

SIZES = {
  "25MB" => 25 * 1024 * 1024,
  "250MB" => 250 * 1024 * 1024
}.freeze

KEYS = SIZES.transform_values { |sz| "crt-tm-benchmark-test_#{sz}" }.freeze

DOWNLOAD_DIR = File.join(Dir.tmpdir, "crt_tm_bench_downloads")

# ---------------------------------------------------------------------------
# Setup — create local source files and upload seed objects for downloads
# ---------------------------------------------------------------------------

def create_source_files
  puts "Creating local source files..."
  files = {}
  SIZES.each do |label, size|
    path = File.join(Dir.tmpdir, "crt_tm_bench_upload_#{size}")
    unless File.exist?(path) && File.size(path) == size
      File.open(path, "wb") do |f|
        chunk = "x" * (1024 * 1024) # write 1MB at a time
        (size / chunk.bytesize).times { f.write(chunk) }
        remainder = size % chunk.bytesize
        f.write("x" * remainder) if remainder.positive?
      end
    end
    files[label] = path
    puts "  ✓ #{path} (#{label})"
  end
  files
end

def setup_s3_seed_data(transfer_manager, source_files)
  puts "Uploading seed objects to S3 for download benchmarks..."
  SIZES.each_key do |label|
    key = KEYS[label]
    transfer_manager.upload_file(source_files[label], bucket: BUCKET, key: key)
    puts "  ✓ s3://#{BUCKET}/#{key} (#{label})"
  end
  puts "Setup complete.\n\n"
end

# ---------------------------------------------------------------------------
# Benchmark helper — times N sequential operations
# ---------------------------------------------------------------------------

def run_sequential(label, iterations)
  errors = 0

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  iterations.times do |i|
    yield i
  rescue StandardError => e
    errors += 1
    warn "  [error] #{e.class}: #{e.message}" if errors <= 5
  end

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  avg = elapsed / iterations

  puts format("  %<label>-40s %<elapsed>8.2fs total  %<avg>8.2fs avg  (%<errors>d errors)",
              label: label, elapsed: elapsed, avg: avg, errors: errors)
  { elapsed: elapsed, avg: avg, errors: errors }
end

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

def cleanup_downloads
  FileUtils.rm_rf(DOWNLOAD_DIR)
end

# ---------------------------------------------------------------------------
# Clients & TransferManagers (with shared concurrent executor)
# ---------------------------------------------------------------------------

default_client = Aws::S3::Client.new

Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
crt_client = Aws::S3::Client.new(max_connections: [25, THREADS * 1.2].min.to_i)

default_executor = Concurrent::FixedThreadPool.new(THREADS)
crt_executor     = Concurrent::FixedThreadPool.new(THREADS)

default_tm = Aws::S3::TransferManager.new(client: default_client, executor: default_executor)
crt_tm     = Aws::S3::TransferManager.new(client: crt_client, executor: crt_executor)

source_files = create_source_files
setup_s3_seed_data(default_tm, source_files)

# ---------------------------------------------------------------------------
# Run benchmarks
# ---------------------------------------------------------------------------

puts "S3 TransferManager Multipart Benchmark"
puts "  Executor threads: #{THREADS}  |  Sequential iterations: #{ITERATIONS}"
puts "=" * 72

SIZES.each_key do |size_label|
  key = KEYS[size_label]
  source = source_files[size_label]

  puts "\n--- upload_file (#{size_label}) ---"

  run_sequential("Net::HTTP", ITERATIONS) do |i|
    default_tm.upload_file(source, bucket: BUCKET, key: "#{key}_bench_#{i}")
  end

  run_sequential("CRT", ITERATIONS) do |i|
    crt_tm.upload_file(source, bucket: BUCKET, key: "#{key}_bench_#{i}")
  end

  puts "\n--- download_file (#{size_label}) ---"

  FileUtils.mkdir_p(DOWNLOAD_DIR)

  run_sequential("Net::HTTP", ITERATIONS) do |i|
    dest = File.join(DOWNLOAD_DIR, "net_#{size_label}_#{i}")
    default_tm.download_file(dest, bucket: BUCKET, key: key)
  ensure
    File.delete(dest) if dest && File.exist?(dest)
  end

  run_sequential("CRT", ITERATIONS) do |i|
    dest = File.join(DOWNLOAD_DIR, "crt_#{size_label}_#{i}")
    crt_tm.download_file(dest, bucket: BUCKET, key: key)
  ensure
    File.delete(dest) if dest && File.exist?(dest)
  end

  cleanup_downloads
end

# ---------------------------------------------------------------------------
# Shutdown executors
# ---------------------------------------------------------------------------

default_executor.shutdown
default_executor.wait_for_termination
crt_executor.shutdown
crt_executor.wait_for_termination

puts "\nDone."
