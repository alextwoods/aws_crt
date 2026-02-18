# frozen_string_literal: true

# S3 benchmark: CRT S3 client vs standard Aws::S3::Client.
#
# Compares download and upload throughput for various object sizes,
# including the CRT file I/O path (recv_filepath / send_filepath)
# vs standard SDK streaming.
#
# ENV vars:
#   BENCH_S3_BUCKET  – S3 bucket name (default: "crt-s3-benchmark")
#   BENCH_S3_REGION  – AWS region     (default: "us-east-1")
#
# Usage:
#   bundle exec rake benchmark:s3
#   bundle exec ruby benchmarks/s3.rb

require "benchmark/ips"
require "aws-sdk-s3"
require "aws_crt/s3"
require "tempfile"

BUCKET = ENV.fetch("BENCH_S3_BUCKET", "crt-s3-benchmark")
REGION = ENV.fetch("BENCH_S3_REGION", "us-east-1")

SIZES = {
  "1MB" => 1 * 1024 * 1024,
  "100MB" => 100 * 1024 * 1024
}.freeze

KEYS = SIZES.transform_values { |sz| "crt-s3-benchmark-test_#{sz}" }.freeze
BODIES = SIZES.transform_values { |sz| "x" * sz }.freeze

# ---------------------------------------------------------------------------
# Setup — ensure test objects exist in S3
# ---------------------------------------------------------------------------

def setup_s3_test_data(client)
  puts "Setting up S3 test data..."
  SIZES.each_key do |label|
    key  = KEYS[label]
    body = BODIES[label]
    client.put_object(bucket: BUCKET, key: key, body: body)
    puts "  ✓ #{key} (#{label})"
  end
  puts "Setup complete.\n\n"
end

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

credentials = Aws::SharedCredentials.new
sdk_client = Aws::S3::Client.new(region: REGION)

crt_client = AwsCrt::S3::Client.new(
  region: REGION,
  credentials: credentials
)

# Seed test data using the standard SDK client
setup_s3_test_data(sdk_client)

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

SIZES.each_key do |label|
  key  = KEYS[label]
  body = BODIES[label]

  # --- Download (in-memory) ------------------------------------------------

  puts "\n--- GetObject #{label} (in-memory) ---"
  Benchmark.ips(quiet: true) do |x|
    x.report("SDK get_object (#{label})") do
      sdk_client.get_object(bucket: BUCKET, key: key).body.read
    end

    x.report("CRT get_object (#{label})") do
      crt_client.get_object(bucket: BUCKET, key: key)
    end

    x.compare!
  end

  # --- Download to file (CRT recv_filepath vs SDK response_target) ---------

  sdk_get_tmpfile = Tempfile.new("sdk_get_bench_#{label}")
  crt_get_tmpfile = Tempfile.new("crt_get_bench_#{label}")

  begin
    puts "\n--- GetObject #{label} (file I/O) ---"
    Benchmark.ips(quiet: true) do |x|
      x.report("SDK get_object to file (#{label})") do
        sdk_client.get_object(bucket: BUCKET, key: key, response_target: sdk_get_tmpfile.path)
      end

      x.report("CRT get_object recv_filepath (#{label})") do
        crt_client.get_object(bucket: BUCKET, key: key, response_target: crt_get_tmpfile.path)
      end

      x.compare!
    end
  ensure
    sdk_get_tmpfile.close!
    crt_get_tmpfile.close!
  end

  # --- Upload (in-memory) --------------------------------------------------

  puts "\n--- PutObject #{label} (in-memory) ---"
  Benchmark.ips(quiet: true) do |x|
    x.report("SDK put_object (#{label})") do
      sdk_client.put_object(bucket: BUCKET, key: key, body: body)
    end

    x.report("CRT put_object (#{label})") do
      crt_client.put_object(bucket: BUCKET, key: key, body: body)
    end

    x.compare!
  end

  # --- Upload from file (CRT send_filepath vs SDK file streaming) ----------

  put_tmpfile = Tempfile.new("put_bench_#{label}")
  put_tmpfile.binmode
  put_tmpfile.write(body)
  put_tmpfile.flush

  begin
    puts "\n--- PutObject #{label} (file I/O) ---"
    Benchmark.ips(quiet: true) do |x|
      x.report("SDK put_object from file (#{label})") do
        File.open(put_tmpfile.path, "rb") do |f|
          sdk_client.put_object(bucket: BUCKET, key: key, body: f)
        end
      end

      x.report("CRT put_object send_filepath (#{label})") do
        File.open(put_tmpfile.path, "rb") do |f|
          crt_client.put_object(bucket: BUCKET, key: key, body: f)
        end
      end

      x.compare!
    end
  ensure
    put_tmpfile.close!
  end
end
