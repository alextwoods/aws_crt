# frozen_string_literal: true

# Feature: crt-s3-client, Property 3: ServiceError Construction Fidelity
#
# For any HTTP error status code (400-599), any Hash of String keys to
# String values as headers, and any String as error_body, constructing
# an AwsCrt::S3::ServiceError should produce an exception where
# status_code, headers, and error_body attributes return the original
# values, and the exception is an instance of both
# AwsCrt::S3::ServiceError and AwsCrt::S3::Error.
#
# **Validates: Requirements 7.1, 7.4**

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt/s3/errors"

# Safe printable ASCII characters for generating random strings.
PRINTABLE_CHARS = (32..126).map(&:chr).freeze unless defined?(PRINTABLE_CHARS)

# Characters valid for HTTP header names (alphanumeric + hyphen).
unless defined?(HEADER_NAME_CHARS)
  HEADER_NAME_CHARS = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + %w[-]).freeze
end

RSpec.describe "Property 3: ServiceError Construction Fidelity" do
  def random_string(min_len = 1, max_len = 50)
    len = rand(min_len..max_len)
    len.times.map { PRINTABLE_CHARS.sample }.join
  end

  def random_header_name
    len = rand(1..20)
    "X-#{len.times.map { HEADER_NAME_CHARS.sample }.join}"
  end

  def random_headers
    count = rand(0..8)
    count.times.each_with_object({}) do |_, hash|
      hash[random_header_name] = random_string
    end
  end

  it "preserves all attributes through construction and reading" do
    property_of do
      status_code = range(400, 599)
      error_body = sized(range(0, 200)) { string }
      message = sized(range(1, 100)) { string }
      [status_code, error_body, message]
    end.check(100) do |(status_code, error_body, message)|
      headers = random_headers

      error = AwsCrt::S3::ServiceError.new(
        message,
        status_code: status_code,
        headers: headers,
        error_body: error_body
      )

      expect(error.status_code).to eq(status_code),
                                   "status_code mismatch: expected #{status_code}, got #{error.status_code}"

      expect(error.headers).to eq(headers),
                               "headers mismatch: expected #{headers.inspect}, got #{error.headers.inspect}"

      expect(error.error_body).to eq(error_body),
                                  "error_body mismatch: expected #{error_body.inspect}, got #{error.error_body.inspect}"

      expect(error.message).to eq(message),
                               "message mismatch: expected #{message.inspect}, got #{error.message.inspect}"
    end
  end

  it "is an instance of both ServiceError and Error" do
    property_of do
      status_code = range(400, 599)
      error_body = sized(range(0, 200)) { string }
      [status_code, error_body]
    end.check(100) do |(status_code, error_body)|
      headers = random_headers

      error = AwsCrt::S3::ServiceError.new(
        "error",
        status_code: status_code,
        headers: headers,
        error_body: error_body
      )

      expect(error).to be_a(AwsCrt::S3::ServiceError),
                       "expected instance of ServiceError, got #{error.class}"

      expect(error).to be_a(AwsCrt::S3::Error),
                       "expected instance of AwsCrt::S3::Error, got #{error.class}"

      expect(error).to be_a(AwsCrt::Error),
                       "expected instance of AwsCrt::Error, got #{error.class}"

      expect(error).to be_a(StandardError),
                       "expected instance of StandardError, got #{error.class}"
    end
  end
end
