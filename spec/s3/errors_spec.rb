# frozen_string_literal: true

require "aws_crt/s3/errors"

# Unit tests for the AwsCrt::S3 error hierarchy.
#
# Requirements: 7.3 — THE module SHALL define an error hierarchy:
#   AwsCrt::S3::Error as the base, with subclasses ServiceError
#   (for HTTP error responses) and NetworkError (for connection/transport failures).
# Requirements: 7.4 — THE ServiceError SHALL expose status_code, headers,
#   and error_body attributes for programmatic error inspection.

RSpec.describe "AwsCrt::S3 error hierarchy" do
  describe "AwsCrt::S3::Error" do
    it "is defined under AwsCrt::S3" do
      expect(AwsCrt::S3::Error).to be_a(Class)
    end

    it "inherits from AwsCrt::Error" do
      expect(AwsCrt::S3::Error.superclass).to eq(AwsCrt::Error)
    end

    it "inherits from StandardError (via AwsCrt::Error)" do
      expect(AwsCrt::S3::Error.ancestors).to include(StandardError)
    end

    it "can be instantiated with a message" do
      error = AwsCrt::S3::Error.new("s3 error")
      expect(error.message).to eq("s3 error")
    end

    it "can be raised and rescued as AwsCrt::Error" do
      expect do
        raise AwsCrt::S3::Error, "s3 error"
      end.to raise_error(AwsCrt::Error)
    end
  end

  describe "AwsCrt::S3::ServiceError" do
    it "inherits from AwsCrt::S3::Error" do
      expect(AwsCrt::S3::ServiceError.superclass).to eq(AwsCrt::S3::Error)
    end

    it "can be rescued as AwsCrt::S3::Error" do
      expect do
        raise AwsCrt::S3::ServiceError.new(
          "Not Found",
          status_code: 404,
          headers: {},
          error_body: ""
        )
      end.to raise_error(AwsCrt::S3::Error)
    end

    it "can be rescued as AwsCrt::Error" do
      expect do
        raise AwsCrt::S3::ServiceError.new(
          "Forbidden",
          status_code: 403,
          headers: {},
          error_body: ""
        )
      end.to raise_error(AwsCrt::Error)
    end

    it "exposes status_code" do
      error = AwsCrt::S3::ServiceError.new(
        "Not Found",
        status_code: 404,
        headers: { "x-amz-request-id" => "abc123" },
        error_body: "<Error><Code>NoSuchKey</Code></Error>"
      )
      expect(error.status_code).to eq(404)
    end

    it "exposes headers" do
      headers = { "x-amz-request-id" => "abc123", "content-type" => "application/xml" }
      error = AwsCrt::S3::ServiceError.new(
        "Forbidden",
        status_code: 403,
        headers: headers,
        error_body: ""
      )
      expect(error.headers).to eq(headers)
    end

    it "exposes error_body" do
      body = "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>"
      error = AwsCrt::S3::ServiceError.new(
        "Forbidden",
        status_code: 403,
        headers: {},
        error_body: body
      )
      expect(error.error_body).to eq(body)
    end

    it "preserves the exception message" do
      error = AwsCrt::S3::ServiceError.new(
        "Internal Server Error",
        status_code: 500,
        headers: {},
        error_body: ""
      )
      expect(error.message).to eq("Internal Server Error")
    end
  end

  describe "AwsCrt::S3::NetworkError" do
    it "inherits from AwsCrt::S3::Error" do
      expect(AwsCrt::S3::NetworkError.superclass).to eq(AwsCrt::S3::Error)
    end

    it "can be rescued as AwsCrt::S3::Error" do
      expect do
        raise AwsCrt::S3::NetworkError, "connection refused"
      end.to raise_error(AwsCrt::S3::Error)
    end

    it "can be rescued as AwsCrt::Error" do
      expect do
        raise AwsCrt::S3::NetworkError, "DNS resolution failed"
      end.to raise_error(AwsCrt::Error)
    end

    it "preserves its message" do
      error = AwsCrt::S3::NetworkError.new("connection timed out")
      expect(error.message).to eq("connection timed out")
    end
  end
end
