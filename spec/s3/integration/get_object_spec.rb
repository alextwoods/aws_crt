# frozen_string_literal: true

# Integration tests for AwsCrt::S3::Client#get_object.
#
# These tests exercise the four body handling modes against a real S3 bucket:
# - Buffered mode (no response_target, no block)
# - File path mode (response_target: String)
# - IO mode (response_target: IO object)
# - Block streaming mode
#
# Requirements: 4.1, 4.2, 4.3, 4.4, 4.5
#
# Environment variables required:
#   S3_BUCKET            — name of the S3 bucket to use
#   S3_REGION            — AWS region of the bucket (e.g. "us-east-1")
#   AWS_ACCESS_KEY_ID    — AWS access key
#   AWS_SECRET_ACCESS_KEY — AWS secret key
#   AWS_SESSION_TOKEN    — (optional) session token for temporary credentials

require "aws_crt/s3/client"
require "stringio"
require "tempfile"
require "securerandom"

GET_OBJECT_REQUIRED_ENV_VARS = %w[S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

RSpec.describe "S3 GetObject integration", :integration do
  def self.s3_integration_configured?
    GET_OBJECT_REQUIRED_ENV_VARS.all? { |var| ENV.fetch(var, nil) && !ENV[var].empty? }
  end

  before(:all) do
    unless self.class.s3_integration_configured?
      skip "S3 integration tests require #{GET_OBJECT_REQUIRED_ENV_VARS.join(", ")} env vars"
    end

    @client = AwsCrt::S3::Client.new(
      region: ENV.fetch("S3_REGION"),
      credentials: AwsCrt::S3::Credentials.new(
        access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
        secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY"),
        session_token: ENV.fetch("AWS_SESSION_TOKEN", nil)
      )
    )

    # Upload a known test object for the GET tests to retrieve.
    @test_key = "aws-crt-ruby-integration-test/get_object_#{SecureRandom.hex(8)}"
    @test_body = "Hello from CRT S3 integration test! #{SecureRandom.hex(16)}"
    @bucket = ENV.fetch("S3_BUCKET")

    @client.put_object(bucket: @bucket, key: @test_key, body: @test_body)
  end

  after(:all) do
    next unless self.class.s3_integration_configured? && @client && @test_key

    begin
      # Clean up the test object.
      @client.put_object(bucket: @bucket, key: @test_key, body: "")
    rescue StandardError
      # Best-effort cleanup; don't fail the suite if deletion fails.
    end
  end

  describe "buffered mode" do
    it "returns the complete body in the response when no response_target or block is given" do
      response = @client.get_object(bucket: @bucket, key: @test_key)

      expect(response).to be_a(AwsCrt::S3::Response)
      expect(response).to be_successful
      expect(response.status_code).to eq(200)
      expect(response.body).to eq(@test_body)
      expect(response.headers).to be_a(Hash)
      expect(response.headers).not_to be_empty
    end
  end

  describe "file path mode" do
    it "writes the object body directly to the specified file path" do
      Tempfile.create("crt-s3-get-object-") do |tmpfile|
        path = tmpfile.path
        tmpfile.close

        response = @client.get_object(
          bucket: @bucket,
          key: @test_key,
          response_target: path
        )

        expect(response).to be_successful
        expect(response.status_code).to eq(200)
        expect(response.body).to be_nil
        expect(File.read(path)).to eq(@test_body)
      end
    end
  end

  describe "IO mode" do
    it "streams the object body to the provided IO object" do
      io = StringIO.new

      response = @client.get_object(
        bucket: @bucket,
        key: @test_key,
        response_target: io
      )

      expect(response).to be_successful
      expect(response.status_code).to eq(200)
      expect(response.body).to be_nil
      expect(io.string).to eq(@test_body)
    end
  end

  describe "block streaming mode" do
    it "yields body chunks to the block" do
      chunks = []

      response = @client.get_object(bucket: @bucket, key: @test_key) do |chunk|
        chunks << chunk
      end

      expect(response).to be_successful
      expect(response.status_code).to eq(200)
      expect(response.body).to be_nil
      expect(chunks.join).to eq(@test_body)
    end
  end

  describe "response metadata" do
    it "includes response headers from S3" do
      response = @client.get_object(bucket: @bucket, key: @test_key)

      expect(response.headers).to be_a(Hash)
      # S3 always returns a Content-Type header
      content_type_key = response.headers.keys.find { |k| k.casecmp("content-type").zero? }
      expect(content_type_key).not_to be_nil
    end
  end
end
