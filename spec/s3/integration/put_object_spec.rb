# frozen_string_literal: true

# Integration tests for AwsCrt::S3::Client#put_object.
#
# These tests exercise the three body input modes and header options
# against a real S3 bucket:
# - String body (in-memory buffer)
# - File body (send_filepath path)
# - IO body (StringIO, read into buffer)
# - content_length and content_type headers
#
# Requirements: 5.1, 5.2, 5.3, 5.7, 5.8
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

PUT_OBJECT_REQUIRED_ENV_VARS = %w[S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

RSpec.describe "S3 PutObject integration", :integration do
  def self.s3_integration_configured?
    PUT_OBJECT_REQUIRED_ENV_VARS.all? { |var| ENV.fetch(var, nil) && !ENV[var].empty? }
  end

  before(:all) do
    unless self.class.s3_integration_configured?
      skip "S3 integration tests require #{PUT_OBJECT_REQUIRED_ENV_VARS.join(", ")} env vars"
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
    key = "aws-crt-ruby-integration-test/put_object_#{label}_#{SecureRandom.hex(8)}"
    @test_keys << key
    key
  end

  # Helper to verify the uploaded content by reading it back.
  def get_body(key)
    @client.get_object(bucket: @bucket, key: key).body
  end

  describe "String body" do
    it "uploads a String body as an in-memory buffer" do
      key = new_test_key("string")
      body = "Hello from CRT S3 put_object String test! #{SecureRandom.hex(16)}"

      response = @client.put_object(bucket: @bucket, key: key, body: body)

      expect(response).to be_a(AwsCrt::S3::Response)
      expect(response).to be_successful
      expect(response.status_code).to eq(200)
      expect(response.headers).to be_a(Hash)
      expect(response.headers).not_to be_empty
      expect(get_body(key)).to eq(body)
    end
  end

  describe "File body" do
    it "uploads a File body using the send_filepath path" do
      key = new_test_key("file")
      content = "Hello from CRT S3 put_object File test! #{SecureRandom.hex(16)}"

      Tempfile.create("crt-s3-put-object-") do |tmpfile|
        tmpfile.write(content)
        tmpfile.flush
        tmpfile.rewind

        response = @client.put_object(bucket: @bucket, key: key, body: tmpfile)

        expect(response).to be_a(AwsCrt::S3::Response)
        expect(response).to be_successful
        expect(response.status_code).to eq(200)
        expect(get_body(key)).to eq(content)
      end
    end
  end

  describe "IO body" do
    it "uploads a StringIO body by reading it into memory" do
      key = new_test_key("io")
      content = "Hello from CRT S3 put_object IO test! #{SecureRandom.hex(16)}"
      io = StringIO.new(content)

      response = @client.put_object(bucket: @bucket, key: key, body: io)

      expect(response).to be_a(AwsCrt::S3::Response)
      expect(response).to be_successful
      expect(response.status_code).to eq(200)
      expect(get_body(key)).to eq(content)
    end
  end

  describe "content_length header" do
    it "sets the Content-Length header on the request" do
      key = new_test_key("content_length")
      body = "content_length test body"

      response = @client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        content_length: body.bytesize
      )

      expect(response).to be_successful
      expect(get_body(key)).to eq(body)
    end
  end

  describe "content_type header" do
    it "sets the Content-Type header on the request" do
      key = new_test_key("content_type")
      body = '{"message": "content_type test"}'

      response = @client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        content_type: "application/json"
      )

      expect(response).to be_successful

      # Verify the object was stored with the correct content type by reading it back.
      get_response = @client.get_object(bucket: @bucket, key: key)
      content_type_key = get_response.headers.keys.find { |k| k.casecmp("content-type").zero? }
      expect(content_type_key).not_to be_nil
      expect(get_response.headers[content_type_key]).to include("application/json")
    end
  end

  describe "response metadata" do
    it "includes response headers from S3" do
      key = new_test_key("metadata")
      response = @client.put_object(bucket: @bucket, key: key, body: "metadata test")

      expect(response.headers).to be_a(Hash)
      expect(response.headers).not_to be_empty
    end
  end
end
