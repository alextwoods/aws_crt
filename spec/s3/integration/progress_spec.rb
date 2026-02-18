# frozen_string_literal: true

# Integration tests for S3 on_progress callback.
#
# These tests verify that:
# - on_progress callback receives bytes_transferred values
# - Progress values are monotonically increasing
#
# Requirements: 8.1
#
# Environment variables required:
#   S3_BUCKET            — name of the S3 bucket to use
#   S3_REGION            — AWS region of the bucket (e.g. "us-east-1")
#   AWS_ACCESS_KEY_ID    — AWS access key
#   AWS_SECRET_ACCESS_KEY — AWS secret key
#   AWS_SESSION_TOKEN    — (optional) session token for temporary credentials

require "aws_crt/s3/client"
require "securerandom"

PROGRESS_REQUIRED_ENV_VARS = %w[S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

RSpec.describe "S3 Progress Reporting integration", :integration do
  def self.s3_integration_configured?
    PROGRESS_REQUIRED_ENV_VARS.all? { |var| ENV.fetch(var, nil) && !ENV[var].empty? }
  end

  before(:all) do
    unless self.class.s3_integration_configured?
      skip "S3 integration tests require #{PROGRESS_REQUIRED_ENV_VARS.join(", ")} env vars"
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
    key = "aws-crt-ruby-integration-test/progress_#{label}_#{SecureRandom.hex(8)}"
    @test_keys << key
    key
  end

  # NOTE: The on_progress callback is currently captured in the Rust layer but
  # not yet wired to call back into Ruby. These tests are structured to verify
  # the feature once it is fully connected. Until then, they are marked pending.

  describe "put_object on_progress" do
    it "invokes the on_progress callback with bytes_transferred values" do
      pending "on_progress callback is not yet wired from Rust to Ruby"

      key = new_test_key("put_progress")
      body = "x" * 1024 # 1 KB payload
      progress_values = []

      on_progress = proc { |bytes_transferred| progress_values << bytes_transferred }

      response = @client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        on_progress: on_progress
      )

      expect(response).to be_successful
      expect(progress_values).not_to be_empty
      progress_values.each { |v| expect(v).to be_a(Integer) }
    end

    it "reports monotonically increasing progress values" do
      pending "on_progress callback is not yet wired from Rust to Ruby"

      key = new_test_key("put_monotonic")
      body = "y" * 2048 # 2 KB payload
      progress_values = []

      on_progress = proc { |bytes_transferred| progress_values << bytes_transferred }

      @client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        on_progress: on_progress
      )

      expect(progress_values.length).to be >= 1
      progress_values.each_cons(2) do |a, b|
        expect(b).to be >= a
      end
    end
  end

  describe "get_object on_progress" do
    it "invokes the on_progress callback with bytes_transferred values" do
      pending "on_progress callback is not yet wired from Rust to Ruby"

      # Upload a test object first.
      key = new_test_key("get_progress")
      body = "z" * 1024
      @client.put_object(bucket: @bucket, key: key, body: body)

      progress_values = []
      on_progress = proc { |bytes_transferred| progress_values << bytes_transferred }

      response = @client.get_object(
        bucket: @bucket,
        key: key,
        on_progress: on_progress
      )

      expect(response).to be_successful
      expect(progress_values).not_to be_empty
      progress_values.each { |v| expect(v).to be_a(Integer) }
    end

    it "reports monotonically increasing progress values" do
      pending "on_progress callback is not yet wired from Rust to Ruby"

      # Upload a test object first.
      key = new_test_key("get_monotonic")
      body = "w" * 2048
      @client.put_object(bucket: @bucket, key: key, body: body)

      progress_values = []
      on_progress = proc { |bytes_transferred| progress_values << bytes_transferred }

      @client.get_object(
        bucket: @bucket,
        key: key,
        on_progress: on_progress
      )

      expect(progress_values.length).to be >= 1
      progress_values.each_cons(2) do |a, b|
        expect(b).to be >= a
      end
    end
  end

  describe "without on_progress callback" do
    it "completes put_object without error when no on_progress is provided" do
      key = new_test_key("no_progress_put")
      body = "no progress callback test"

      response = @client.put_object(bucket: @bucket, key: key, body: body)

      expect(response).to be_successful
    end

    it "completes get_object without error when no on_progress is provided" do
      key = new_test_key("no_progress_get")
      body = "no progress callback test"
      @client.put_object(bucket: @bucket, key: key, body: body)

      response = @client.get_object(bucket: @bucket, key: key)

      expect(response).to be_successful
      expect(response.body).to eq(body)
    end
  end
end
