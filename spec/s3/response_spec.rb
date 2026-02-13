# frozen_string_literal: true

require "aws_crt/s3/response"

# Unit tests for the AwsCrt::S3::Response object.
#
# Requirements: 6.1 — THE response object SHALL have a status_code attribute
#   containing the HTTP status code as an Integer.
# Requirements: 6.2 — THE response object SHALL have a headers attribute
#   containing response headers as a Hash of String keys to String values.
# Requirements: 6.3 — THE response object SHALL have a body attribute
#   containing the response body as a String or nil (when streamed).
# Requirements: 6.4 — THE response object SHALL include a checksum_validated
#   attribute indicating the algorithm used for validation.

RSpec.describe AwsCrt::S3::Response do
  describe "attribute accessors" do
    it "exposes status_code" do
      response = described_class.new(status_code: 200, headers: {})
      expect(response.status_code).to eq(200)
    end

    it "exposes headers" do
      headers = { "content-type" => "application/xml", "x-amz-request-id" => "abc123" }
      response = described_class.new(status_code: 200, headers: headers)
      expect(response.headers).to eq(headers)
    end

    it "exposes body" do
      response = described_class.new(status_code: 200, headers: {}, body: "hello world")
      expect(response.body).to eq("hello world")
    end

    it "exposes checksum_validated" do
      response = described_class.new(status_code: 200, headers: {}, checksum_validated: "CRC32")
      expect(response.checksum_validated).to eq("CRC32")
    end
  end

  describe "default values" do
    it "defaults body to nil" do
      response = described_class.new(status_code: 200, headers: {})
      expect(response.body).to be_nil
    end

    it "defaults checksum_validated to nil" do
      response = described_class.new(status_code: 200, headers: {})
      expect(response.checksum_validated).to be_nil
    end
  end

  describe "#successful?" do
    it "returns true for 200" do
      response = described_class.new(status_code: 200, headers: {})
      expect(response.successful?).to be true
    end

    it "returns true for 204" do
      response = described_class.new(status_code: 204, headers: {})
      expect(response.successful?).to be true
    end

    it "returns true for 299" do
      response = described_class.new(status_code: 299, headers: {})
      expect(response.successful?).to be true
    end

    it "returns false for 199" do
      response = described_class.new(status_code: 199, headers: {})
      expect(response.successful?).to be false
    end

    it "returns false for 300" do
      response = described_class.new(status_code: 300, headers: {})
      expect(response.successful?).to be false
    end

    it "returns false for 404" do
      response = described_class.new(status_code: 404, headers: {})
      expect(response.successful?).to be false
    end

    it "returns false for 500" do
      response = described_class.new(status_code: 500, headers: {})
      expect(response.successful?).to be false
    end
  end
end
