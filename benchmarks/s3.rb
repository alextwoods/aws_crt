# frozen_string_literal: true

# S3 benchmark: CRT S3 client vs SDK S3 client vs SDK TransferManager.
#
# Compares download and upload throughput (MB/s) for large objects.
# Uses single-iteration timing (no warmup) since the larger sizes
# are too slow for benchmark-ips style repeated runs.
#
# Sizes:
#   100MB  – tested both in-memory and file I/O
#   500MB  – file I/O only
#   1GB    – file I/O only
#
# ENV vars:
#   BENCH_S3_BUCKET  – S3 bucket name (default: "test-bucket-alexwoo-2")
#   BENCH_S3_REGION  – AWS region     (default: "us-west-2")
#   BENCH_THREADS    – TM executor thread pool size (default: 8)
#
# Usage:
#   bundle exec rake benchmark:s3
#   bundle exec ruby benchmarks/s3.rb

require "concurrent"
require "aws-sdk-s3"
require "aws_crt/s3"
require "tmpdir"
require "fileutils"

BUCKET  = ENV.fetch("BENCH_S3_BUCKET", "test-bucket-alexwoo-2")
REGION  = ENV.fetch("BENCH_S3_REGION", "us-west-1")
THREADS = Integer(ENV.fetch("BENCH_THREADS", "8"))

MB = 1024 * 1024

SIZES = {
  "100MB" => 100 * MB,
  "500MB" => 500 * MB,
  "1GB" => 1024 * MB
}.freeze

# Only 100MB is tested in-memory; larger sizes are file I/O only.
IN_MEMORY_SIZES = %w[100MB].freeze

KEYS = SIZES.transform_values { |sz| "crt-s3-benchmark-test_#{sz}" }.freeze

WORK_DIR = File.join(Dir.tmpdir, "crt_s3_bench")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def mb_s(bytes, elapsed)
  (bytes.to_f / MB / elapsed).round(2)
end

def time_it(label, size_bytes)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  throughput = mb_s(size_bytes, elapsed)
  puts format("  %<label>-45s %<elapsed>8.2fs  %<throughput>8.2f MB/s",
              label: label, elapsed: elapsed, throughput: throughput)
  { elapsed: elapsed, throughput: throughput }
end

# Create a local file of the given size, reusing it if it already exists.
def source_file_path(label, size)
  path = File.join(WORK_DIR, "upload_source_#{label}")
  return path if File.exist?(path) && File.size(path) == size

  File.open(path, "wb") do |f|
    chunk = "x" * MB
    (size / MB).times { f.write(chunk) }
    remainder = size % MB
    f.write("x" * remainder) if remainder.positive?
  end
  path
end

# ---------------------------------------------------------------------------
# Setup — create source files and seed S3 objects
# ---------------------------------------------------------------------------

def setup(transfer_manager)
  FileUtils.mkdir_p(WORK_DIR)

  puts "Creating local source files..."
  source_files = {}
  SIZES.each do |label, size|
    source_files[label] = source_file_path(label, size)
    puts "  ✓ #{source_files[label]} (#{label})"
  end

  puts "Uploading seed objects to S3..."
  SIZES.each_key do |label|
    key = KEYS[label]
    transfer_manager.upload_file(source_files[label], bucket: BUCKET, key: key)
    puts "  ✓ s3://#{BUCKET}/#{key} (#{label})"
  end
  puts "Setup complete.\n\n"

  source_files
end

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

sdk_client = Aws::S3::Client.new(region: REGION)
credentials = sdk_client.config.credentials

crt_client = AwsCrt::S3::Client.new(
  region: REGION,
  credentials: credentials
)

tm_executor = Concurrent::FixedThreadPool.new(THREADS)
transfer_manager = Aws::S3::TransferManager.new(
  client: sdk_client,
  executor: tm_executor
)

source_files = setup(transfer_manager)

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

puts "S3 Throughput Benchmark"
puts "  Region: #{REGION}  |  TM threads: #{THREADS}"
puts "=" * 72

SIZES.each_key do |label|
  key  = KEYS[label]
  size = SIZES[label]

  # --- In-memory download/upload (100MB only) ------------------------------

  if IN_MEMORY_SIZES.include?(label)
    puts "\n--- GetObject #{label} (in-memory) ---"

    time_it("SDK get_object", size) do
      sdk_client.get_object(bucket: BUCKET, key: key).body.read
    end

    time_it("CRT get_object", size) do
      crt_client.get_object(bucket: BUCKET, key: key)
    end

    puts "\n--- PutObject #{label} (in-memory) ---"

    body = File.binread(source_files[label])

    time_it("SDK put_object", size) do
      sdk_client.put_object(bucket: BUCKET, key: key, body: body)
    end

    time_it("CRT put_object", size) do
      crt_client.put_object(bucket: BUCKET, key: key, body: body)
    end
  end

  # --- File I/O download ---------------------------------------------------

  puts "\n--- GetObject #{label} (file I/O) ---"

  sdk_dl = File.join(WORK_DIR, "sdk_get_#{label}")
  crt_dl = File.join(WORK_DIR, "crt_get_#{label}")
  tm_dl  = File.join(WORK_DIR, "tm_get_#{label}")

  begin
    time_it("SDK get_object to file", size) do
      sdk_client.get_object(bucket: BUCKET, key: key, response_target: sdk_dl)
    end

    time_it("CRT get_object to file", size) do
      crt_client.get_object(bucket: BUCKET, key: key, response_target: crt_dl)
    end

    time_it("TM  download_file", size) do
      transfer_manager.download_file(tm_dl, bucket: BUCKET, key: key)
    end
  ensure
    [sdk_dl, crt_dl, tm_dl].each { |f| FileUtils.rm_f(f) }
  end

  # --- File I/O upload -----------------------------------------------------

  puts "\n--- PutObject #{label} (file I/O) ---"

  src = source_files[label]

  time_it("SDK put_object from file", size) do
    File.open(src, "rb") do |f|
      sdk_client.put_object(bucket: BUCKET, key: key, body: f)
    end
  end

  time_it("CRT put_object from file", size) do
    File.open(src, "rb") do |f|
      crt_client.put_object(bucket: BUCKET, key: key, body: f)
    end
  end

  time_it("TM  upload_file", size) do
    transfer_manager.upload_file(src, bucket: BUCKET, key: key)
  end
end

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

tm_executor.shutdown
tm_executor.wait_for_termination

puts "\nDone."
