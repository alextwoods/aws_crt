# frozen_string_literal: true

# Feature: crt-s3-client, Property 5: Checksum Algorithm Validation
#
# For any checksum_algorithm value from the set {CRC32, CRC32C, SHA1, SHA256},
# when put_object is called with that algorithm, the CRT checksum configuration
# should specify the corresponding algorithm. For any string not in that set,
# the client should reject the value with an error.
#
# **Validates: Requirements 5.6**

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt/s3/client"

VALID_ALGORITHMS = %w[CRC32 CRC32C SHA1 SHA256].freeze unless defined?(VALID_ALGORITHMS)

RSpec.describe "Property 5: Checksum Algorithm Validation" do
  let(:client) do
    allow_any_instance_of(AwsCrt::S3::Client).to receive(:_native_initialize)
    AwsCrt::S3::Client.new(
      region: "us-east-1",
      credentials: AwsCrt::S3::Credentials.new(
        access_key_id: "AKID",
        secret_access_key: "secret"
      )
    )
  end

  it "accepts all four valid checksum algorithms and passes them to the native layer" do
    property_of do
      choose(*VALID_ALGORITHMS)
    end.check(100) do |algorithm|
      captured_params = nil
      allow(client).to receive(:_native_put_object) do |params|
        captured_params = params
        { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      end

      response = client.put_object(
        bucket: "test-bucket",
        key: "test-key",
        body: "data",
        checksum_algorithm: algorithm
      )

      expect(response).to be_a(AwsCrt::S3::Response),
                          "expected a Response for algorithm #{algorithm}, got #{response.class}"

      expect(response.status_code).to eq(200),
                                      "expected status 200 for algorithm #{algorithm}, got #{response.status_code}"

      expect(captured_params).not_to be_nil,
                                     "expected _native_put_object to be called for algorithm #{algorithm}"

      expect(captured_params[:checksum_algorithm]).to eq(algorithm),
                                                      "checksum_algorithm mismatch: expected #{algorithm.inspect}, " \
                                                      "got #{captured_params[:checksum_algorithm].inspect}"
    end
  end

  it "rejects any string not in the valid algorithm set with ArgumentError" do
    property_of do
      # Generate random strings and guard against accidentally hitting a valid algorithm.
      s = sized(range(1, 30)) { string }
      guard(!VALID_ALGORITHMS.include?(s))
      s
    end.check(100) do |invalid_algorithm|
      expect do
        client.put_object(
          bucket: "test-bucket",
          key: "test-key",
          body: "data",
          checksum_algorithm: invalid_algorithm
        )
      end.to raise_error(ArgumentError, /invalid checksum_algorithm/),
             "expected ArgumentError for invalid algorithm #{invalid_algorithm.inspect}"
    end
  end
end
