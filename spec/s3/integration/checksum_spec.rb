# frozen_string_literal: true

# Integration tests for S3 checksum compute (put_object) and validate (get_object).
#
# These tests verify that:
# - put_object with each checksum_algorithm uploads successfully
# - get_object with checksum_mode: 'ENABLED' validates the checksum
# - The response includes checksum_validated indicating the algorithm used
#
# Requirements: 4.8, 5.6
#
# Environment variables required:
#   S3_BUCKET            — name of the S3 bucket to use
#   S3_REGION            — AWS region of the bucket (e.g. "us-east-1")
#   AWS_ACCESS_KEY_ID    — AWS access key
#   AWS_SECRET_ACCESS_KEY — AWS secret key
#   AWS_SESSION_TOKEN    — (optional) session token for temporary credentials

require "aws_crt/s3/client"
require "securerandom"

CHECKSUM_REQUIRED_ENV_VARS = %w[S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

RSpec.describe "S3 Checksum integration", :integration do
  def self.s3_integration_configured?
    CHECKSUM_REQUIRED_ENV_VARS.all? { |var| ENV.fetch(var, nil) && !ENV[var].empty? }
  end

  before(:all) do
    unless self.class.s3_integration_configured?
      skip "S3 integration tests require #{CHECKSUM_REQUIRED_ENV_VARS.join(", ")} env vars"
    end

    @client = AwsCrt::S3::Client.new(
      region: ENV.fetch("S3_REGION"),
      credentials: AwsCrt::S3::Credentials.new(
        access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY"),
        session_token: ENV.fetch("AWS_SESSION_TOKEN", nil)
      )
    )

    @bucket = ENV.fetch("S3_BUCKET")
    @test_keys = []
  end

  after(:all) do
    next unless self.class.s3_integration_configured? && @client && @test_keys&.any?

    @test_keys.each do |key|
      @client.put_object(bucket: @bucket, key: key, body: "")
    rescue StandardError
      # Best-effort cleanup; don't fail the suite if deletion fails.
    end
  end

  # Helper to generate a unique test key and track it for cleanup.
  def new_test_key(label)
    key = "aws-crt-ruby-integration-test/checksum_#{label}_#{SecureRandom.hex(8)}"
    @test_keys << key
    key
  end

  describe "put_object with checksum_algorithm" do
    %w[CRC32 CRC32C SHA1 SHA256].each do |algorithm|
      it "uploads successfully with checksum_algorithm: #{algorithm}" do
        key = new_test_key(algorithm.downcase)
        body = "Checksum test body for #{algorithm} #{SecureRandom.hex(16)}"

        response = @client.put_object(
          bucket: @bucket,
          key: key,
          body: body,
          checksum_algorithm: algorithm
        )

        expect(response).to be_a(AwsCrt::S3::Response)
        expect(response).to be_successful
        expect(response.status_code).to eq(200)

        # Verify the object was stored correctly by reading it back.
        get_response = @client.get_object(bucket: @bucket, key: key)
        expect(get_response.body).to eq(body)
      end
    end
  end

  describe "get_object with checksum_mode: ENABLED" do
    %w[CRC32 CRC32C SHA1 SHA256].each do |algorithm|
      it "validates the #{algorithm} checksum on download" do
        key = new_test_key("validate_#{algorithm.downcase}")
        body = "Checksum validation test for #{algorithm} #{SecureRandom.hex(16)}"

        # Upload with a checksum so S3 stores it.
        @client.put_object(
          bucket: @bucket,
          key: key,
          body: body,
          checksum_algorithm: algorithm
        )

        # Download with checksum validation enabled.
        response = @client.get_object(
          bucket: @bucket,
          key: key,
          checksum_mode: "ENABLED"
        )

        expect(response).to be_successful
        expect(response.body).to eq(body)
        expect(response.checksum_validated).to eq(algorithm)
      end
    end
  end
end
