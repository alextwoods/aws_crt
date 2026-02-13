# frozen_string_literal: true

# Feature: crt-s3-client, Property 1: S3 Client Configuration Acceptance
#
# For any valid combination of optional configuration parameters
# (throughput_target_gbps as a positive Float, part_size as a positive
# Integer, multipart_upload_threshold as a positive Integer,
# memory_limit_in_bytes as a positive Integer, max_active_connections_override
# as a positive Integer), creating an S3 client with those parameters and
# valid credentials should succeed without raising an error, and the client
# should be usable.
#
# **Validates: Requirements 3.2, 3.3, 3.4, 3.5, 3.6**

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt/s3/client"

# CRT constraints:
# - memory_limit_in_bytes must be >= 1 GiB when specified
# - part_size must be smaller than memory_limit_in_bytes
#
# We keep values reasonable to avoid excessive resource consumption
# during property testing while still exercising a wide range.
GIB = 1024 * 1024 * 1024 unless defined?(GIB)

MIN_THROUGHPUT_GBPS = 0.1 unless defined?(MIN_THROUGHPUT_GBPS)
MAX_THROUGHPUT_GBPS = 100.0 unless defined?(MAX_THROUGHPUT_GBPS)
MIN_PART_SIZE = 5 * 1024 * 1024 unless defined?(MIN_PART_SIZE)           # 5 MB (S3 multipart minimum)
MAX_PART_SIZE = 100 * 1024 * 1024 unless defined?(MAX_PART_SIZE)         # 100 MB
MIN_MEMORY_LIMIT = GIB unless defined?(MIN_MEMORY_LIMIT)                 # CRT requires >= 1 GiB
MAX_MEMORY_LIMIT = (2 * GIB) unless defined?(MAX_MEMORY_LIMIT)           # Keep reasonable for testing
MAX_UPLOAD_THRESHOLD = 100 * 1024 * 1024 unless defined?(MAX_UPLOAD_THRESHOLD) # 100 MB
MAX_CONNECTIONS = 100 unless defined?(MAX_CONNECTIONS)

RSpec.describe "Property 1: S3 Client Configuration Acceptance" do
  # Dummy credentials — the CRT does not validate credentials at client
  # creation time, only when making requests.
  let(:base_options) do
    {
      region: "us-east-1",
      credentials: AwsCrt::S3::Credentials.new(
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      )
    }
  end

  it "creates a client successfully for any valid configuration combination" do
    property_of do
      # Generate a throughput value in [MIN, MAX] rounded to 2 decimal places
      throughput_int = range(
        (MIN_THROUGHPUT_GBPS * 100).to_i,
        (MAX_THROUGHPUT_GBPS * 100).to_i
      )
      throughput = throughput_int / 100.0

      part_size = range(MIN_PART_SIZE, MAX_PART_SIZE)
      upload_threshold = range(MIN_PART_SIZE, MAX_UPLOAD_THRESHOLD)
      # memory_limit must be >= 1 GiB and > part_size (CRT constraint)
      memory_limit = range(MIN_MEMORY_LIMIT, MAX_MEMORY_LIMIT)
      connections = range(1, MAX_CONNECTIONS)

      [throughput, part_size, upload_threshold, memory_limit, connections]
    end.check(100) do |(throughput, part_size, upload_threshold, memory_limit, connections)|
      options = base_options.merge(
        throughput_target_gbps: throughput,
        part_size: part_size,
        multipart_upload_threshold: upload_threshold,
        memory_limit_in_bytes: memory_limit,
        max_active_connections_override: connections
      )

      client = nil
      expect do
        client = AwsCrt::S3::Client.new(options)
      end.not_to raise_error,
                 "expected client creation to succeed with throughput=#{throughput}, " \
                 "part_size=#{part_size}, upload_threshold=#{upload_threshold}, " \
                 "memory_limit=#{memory_limit}, connections=#{connections}"

      expect(client).to be_a(AwsCrt::S3::Client),
                        "expected an AwsCrt::S3::Client instance, got #{client.class}"
    end
  end

  it "creates a client with only a subset of optional parameters" do
    property_of do
      # Randomly decide which optional params to include (bitmask of 5 bits)
      flags = range(0, 31)

      throughput_int = range(
        (MIN_THROUGHPUT_GBPS * 100).to_i,
        (MAX_THROUGHPUT_GBPS * 100).to_i
      )
      throughput = throughput_int / 100.0

      part_size = range(MIN_PART_SIZE, MAX_PART_SIZE)
      upload_threshold = range(MIN_PART_SIZE, MAX_UPLOAD_THRESHOLD)
      memory_limit = range(MIN_MEMORY_LIMIT, MAX_MEMORY_LIMIT)
      connections = range(1, MAX_CONNECTIONS)

      [flags, throughput, part_size, upload_threshold, memory_limit, connections]
    end.check(100) do |(flags, throughput, part_size, upload_threshold, memory_limit, connections)|
      options = base_options.dup

      options[:throughput_target_gbps] = throughput if flags.anybits?(1)
      options[:part_size] = part_size if flags.anybits?(2)
      options[:multipart_upload_threshold] = upload_threshold if flags.anybits?(4)
      options[:memory_limit_in_bytes] = memory_limit if flags.anybits?(8)
      options[:max_active_connections_override] = connections if flags.anybits?(16)

      client = nil
      expect do
        client = AwsCrt::S3::Client.new(options)
      end.not_to raise_error,
                 "expected client creation to succeed with options subset " \
                 "(flags=#{flags}, options=#{options.except(:region, :credentials)})"

      expect(client).to be_a(AwsCrt::S3::Client),
                        "expected an AwsCrt::S3::Client instance, got #{client.class}"
    end
  end
end
