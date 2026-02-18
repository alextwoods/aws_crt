# frozen_string_literal: true

# Integration tests for S3 error handling.
#
# These tests verify that:
# - ServiceError is raised for non-existent bucket/key (403/404)
# - NetworkError is raised for unreachable endpoints
# - Error attributes (status_code, headers, error_body) are populated
#
# Requirements: 7.1, 7.2
#
# Environment variables required:
#   S3_BUCKET            — name of the S3 bucket to use
#   S3_REGION            — AWS region of the bucket (e.g. "us-east-1")
#   AWS_ACCESS_KEY_ID    — AWS access key
#   AWS_SECRET_ACCESS_KEY — AWS secret key
#   AWS_SESSION_TOKEN    — (optional) session token for temporary credentials

require "aws_crt/s3/client"
require "securerandom"

ERROR_HANDLING_REQUIRED_ENV_VARS = %w[S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

RSpec.describe "S3 Error Handling integration", :integration do
  def self.s3_integration_configured?
    ERROR_HANDLING_REQUIRED_ENV_VARS.all? { |var| ENV.fetch(var, nil) && !ENV[var].empty? }
  end

  before(:all) do
    unless self.class.s3_integration_configured?
      skip "S3 integration tests require #{ERROR_HANDLING_REQUIRED_ENV_VARS.join(", ")} env vars"
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
  end

  describe "ServiceError for non-existent key" do
    it "raises ServiceError with a 404 status when getting a key that does not exist" do
      nonexistent_key = "aws-crt-ruby-integration-test/nonexistent_#{SecureRandom.hex(16)}"

      expect do
        @client.get_object(bucket: @bucket, key: nonexistent_key)
      end.to raise_error(AwsCrt::S3::ServiceError) { |error|
        expect(error).to be_a(AwsCrt::S3::Error)
        expect(error.status_code).to be_a(Integer)
        expect([403, 404]).to include(error.status_code)
        expect(error.headers).to be_a(Hash)
        expect(error.headers).not_to be_empty
        expect(error.error_body).to be_a(String)
        expect(error.error_body).not_to be_empty
        expect(error.message).to be_a(String)
        expect(error.message).not_to be_empty
      }
    end
  end

  describe "ServiceError for non-existent bucket" do
    it "raises ServiceError when accessing a bucket that does not exist" do
      fake_bucket = "aws-crt-ruby-nonexistent-bucket-#{SecureRandom.hex(8)}"

      expect do
        @client.get_object(bucket: fake_bucket, key: "any-key")
      end.to raise_error(AwsCrt::S3::ServiceError) { |error|
        expect(error).to be_a(AwsCrt::S3::Error)
        expect(error.status_code).to be_a(Integer)
        expect(error.status_code).to be >= 400
        expect(error.headers).to be_a(Hash)
        expect(error.error_body).to be_a(String)
      }
    end
  end

  describe "ServiceError attributes" do
    it "populates status_code, headers, and error_body" do
      nonexistent_key = "aws-crt-ruby-integration-test/error_attrs_#{SecureRandom.hex(16)}"

      begin
        @client.get_object(bucket: @bucket, key: nonexistent_key)
        raise "Expected ServiceError to be raised"
      rescue AwsCrt::S3::ServiceError => e
        # status_code should be an HTTP error code
        expect(e.status_code).to be_a(Integer)
        expect(e.status_code).to be_between(400, 599)

        # headers should be a non-empty Hash
        expect(e.headers).to be_a(Hash)
        expect(e.headers).not_to be_empty

        # error_body should contain S3's XML error response
        expect(e.error_body).to be_a(String)
        expect(e.error_body).not_to be_empty
      end
    end
  end

  describe "NetworkError for unreachable endpoint" do
    it "raises NetworkError when the endpoint is unreachable" do
      # Create a client pointing to a fake/unreachable region to trigger
      # a network-level failure (DNS resolution or connection failure).
      unreachable_client = AwsCrt::S3::Client.new(
        region: "us-fake-region-99",
        credentials: AwsCrt::S3::Credentials.new(
          access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
          secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY"),
          session_token: ENV.fetch("AWS_SESSION_TOKEN", nil)
        )
      )

      expect do
        unreachable_client.get_object(bucket: "any-bucket", key: "any-key")
      end.to raise_error(AwsCrt::S3::NetworkError) { |error|
        expect(error).to be_a(AwsCrt::S3::Error)
        expect(error.message).to be_a(String)
        expect(error.message).not_to be_empty
      }
    end
  end
end
