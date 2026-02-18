# frozen_string_literal: true

# Feature: crt-s3-client, Property 4: Request Header Construction from Parameters
#
# For any non-empty String as content_type and any positive Integer as
# content_length, when put_object builds an HTTP request message with
# those parameters, the resulting request headers should contain a
# Content-Type header matching the input content_type and a
# Content-Length header matching the string representation of the input
# content_length.
#
# **Validates: Requirements 5.7, 5.8**

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt/s3/client"

# Safe printable ASCII characters for generating random content_type strings.
PRINTABLE_CHARS = (32..126).map(&:chr).freeze unless defined?(PRINTABLE_CHARS)

RSpec.describe "Property 4: Request Header Construction from Parameters" do
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

  def random_content_type
    # Generate realistic MIME-like content types: type/subtype
    types = %w[text application image audio video multipart]
    subtypes = %w[plain html json xml octet-stream csv pdf png jpeg gif]
    "#{types.sample}/#{subtypes.sample}"
  end

  it "passes content_type and content_length through to the native layer" do
    property_of do
      range(1, 10_000_000_000)
    end.check(100) do |content_length|
      content_type = random_content_type

      captured_params = nil
      allow(client).to receive(:_native_put_object) do |params|
        captured_params = params
        { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      end

      client.put_object(
        bucket: "test-bucket",
        key: "test-key",
        body: "data",
        content_type: content_type,
        content_length: content_length
      )

      expect(captured_params).not_to be_nil,
                                     "expected _native_put_object to be called"

      expect(captured_params[:content_type]).to eq(content_type),
                                                "content_type mismatch: expected #{content_type.inspect}, " \
                                                "got #{captured_params[:content_type].inspect}"

      expect(captured_params[:content_length]).to eq(content_length),
                                                  "content_length mismatch: expected #{content_length}, " \
                                                  "got #{captured_params[:content_length].inspect}"
    end
  end

  it "passes content_type alone when content_length is not provided" do
    property_of do
      sized(range(1, 50)) { string }
    end.check(100) do |_random_seed|
      content_type = random_content_type

      captured_params = nil
      allow(client).to receive(:_native_put_object) do |params|
        captured_params = params
        { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      end

      client.put_object(
        bucket: "test-bucket",
        key: "test-key",
        body: "data",
        content_type: content_type
      )

      expect(captured_params[:content_type]).to eq(content_type),
                                                "content_type mismatch: expected #{content_type.inspect}, " \
                                                "got #{captured_params[:content_type].inspect}"

      expect(captured_params).not_to have_key(:content_length),
                                     "expected content_length to not be present when not provided"
    end
  end

  it "passes content_length alone when content_type is not provided" do
    property_of do
      range(1, 10_000_000_000)
    end.check(100) do |content_length|
      captured_params = nil
      allow(client).to receive(:_native_put_object) do |params|
        captured_params = params
        { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      end

      client.put_object(
        bucket: "test-bucket",
        key: "test-key",
        body: "data",
        content_length: content_length
      )

      expect(captured_params[:content_length]).to eq(content_length),
                                                  "content_length mismatch: expected #{content_length}, " \
                                                  "got #{captured_params[:content_length].inspect}"

      expect(captured_params).not_to have_key(:content_type),
                                     "expected content_type to not be present when not provided"
    end
  end
end
