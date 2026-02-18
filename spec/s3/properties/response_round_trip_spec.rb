# frozen_string_literal: true

# Feature: crt-s3-client, Property 2: Response Object Round-Trip
#
# For any valid HTTP status code (100-599), any Hash of String keys to
# String values as headers, any String (or nil) as body, and any String
# (or nil) as checksum_validated, constructing an AwsCrt::S3::Response
# and reading its attributes should return values identical to the
# constructor arguments.
#
# **Validates: Requirements 4.7, 5.5, 6.1, 6.2, 6.3, 6.4**

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt/s3/response"

# Safe printable ASCII characters for generating random strings.
PRINTABLE_CHARS = (32..126).map(&:chr).freeze unless defined?(PRINTABLE_CHARS)

# Characters valid for HTTP header names (alphanumeric + hyphen).
unless defined?(HEADER_NAME_CHARS)
  HEADER_NAME_CHARS = (("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + %w[-]).freeze
end

RSpec.describe "Property 2: Response Object Round-Trip" do
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
      status_code = range(100, 599)
      body = freq([3, :call, proc { Rantly.new.sized(range(0, 200)) { string } }],
                  [1, :call, proc {}])
      checksum = freq([1, :call, proc { Rantly.new.choose("CRC32", "CRC32C", "SHA1", "SHA256") }],
                      [1, :call, proc {}])
      [status_code, body, checksum]
    end.check(100) do |(status_code, body, checksum)|
      headers = random_headers

      response = AwsCrt::S3::Response.new(
        status_code: status_code,
        headers: headers,
        body: body,
        checksum_validated: checksum
      )

      expect(response.status_code).to eq(status_code),
                                      "status_code mismatch: expected #{status_code}, got #{response.status_code}"

      expect(response.headers).to eq(headers),
                                  "headers mismatch: expected #{headers.inspect}, got #{response.headers.inspect}"

      expect(response.body).to eq(body),
                               "body mismatch: expected #{body.inspect}, got #{response.body.inspect}"

      expect(response.checksum_validated).to eq(checksum),
                                             "checksum_validated mismatch: expected #{checksum.inspect}, " \
                                             "got #{response.checksum_validated.inspect}"
    end
  end

  it "successful? is consistent with status_code" do
    property_of do
      range(100, 599)
    end.check(100) do |status_code|
      response = AwsCrt::S3::Response.new(status_code: status_code, headers: {})

      expected_successful = status_code >= 200 && status_code < 300
      expect(response.successful?).to eq(expected_successful),
                                      "successful? should be #{expected_successful} for status #{status_code}, " \
                                      "got #{response.successful?}"
    end
  end
end
