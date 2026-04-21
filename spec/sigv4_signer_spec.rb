# frozen_string_literal: true

require "spec_helper"
require "digest"

RSpec.describe AwsCrt::Sigv4Signer do
  # Test credentials (not real)
  let(:access_key_id) { "AKIAIOSFODNN7EXAMPLE" }
  let(:secret_access_key) { "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" }
  let(:region) { "us-east-1" }

  describe ".new" do
    it "creates a signer with a service name" do
      signer = described_class.new(service: "sts")
      expect(signer).to be_a(described_class)
    end

    it "raises ArgumentError when service is missing" do
      expect { described_class.new }.to raise_error(ArgumentError, /service/)
    end

    it "accepts all configuration options" do
      signer = described_class.new(
        service: "s3",
        apply_sha256_header: false,
        use_double_uri_encode: false,
        normalize_uri_path: false,
        sign_body: true
      )
      expect(signer).to be_a(described_class)
    end
  end

  describe "#sign_request" do
    subject(:signer) { described_class.new(service: "sts") }

    let(:base_request) do
      {
        region: region,
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        method: "POST",
        uri: "/",
        headers: [
          ["host", "sts.amazonaws.com"],
          ["content-type", "application/x-www-form-urlencoded"]
        ],
        body: "Action=GetCallerIdentity&Version=2011-06-15"
      }
    end

    it "returns a hash with :headers, :method, and :uri" do
      result = signer.sign_request(**base_request)
      expect(result).to include(:headers, :method, :uri)
    end

    it "preserves the original method" do
      result = signer.sign_request(**base_request)
      expect(result[:method]).to eq("POST")
    end

    it "preserves the original URI" do
      result = signer.sign_request(**base_request)
      expect(result[:uri]).to eq("/")
    end

    it "preserves original headers" do
      result = signer.sign_request(**base_request)
      header_names = result[:headers].map(&:first)
      expect(header_names).to include("host", "content-type")
    end

    it "adds an Authorization header with AWS4-HMAC-SHA256" do
      result = signer.sign_request(**base_request)
      auth = result[:headers].find { |n, _| n == "Authorization" }&.last
      expect(auth).to start_with("AWS4-HMAC-SHA256")
    end

    it "includes the correct credential scope in Authorization" do
      result = signer.sign_request(**base_request)
      auth = result[:headers].find { |n, _| n == "Authorization" }&.last
      expect(auth).to include("Credential=#{access_key_id}/")
      expect(auth).to include("/#{region}/sts/aws4_request")
    end

    it "includes SignedHeaders in Authorization" do
      result = signer.sign_request(**base_request)
      auth = result[:headers].find { |n, _| n == "Authorization" }&.last
      expect(auth).to include("SignedHeaders=")
    end

    it "includes Signature in Authorization" do
      result = signer.sign_request(**base_request)
      auth = result[:headers].find { |n, _| n == "Authorization" }&.last
      expect(auth).to match(/Signature=[0-9a-f]{64}/)
    end

    it "adds an X-Amz-Date header" do
      result = signer.sign_request(**base_request)
      date = result[:headers].find { |n, _| n == "X-Amz-Date" }&.last
      expect(date).to match(/\A\d{8}T\d{6}Z\z/)
    end

    it "adds x-amz-content-sha256 header by default" do
      result = signer.sign_request(**base_request)
      sha = result[:headers].find { |n, _| n == "x-amz-content-sha256" }&.last
      expect(sha).to eq("UNSIGNED-PAYLOAD")
    end

    context "with session token" do
      it "adds X-Amz-Security-Token header" do
        result = signer.sign_request(
          **base_request,
          session_token: "MySessionToken123"
        )
        token = result[:headers].find { |n, _| n == "X-Amz-Security-Token" }&.last
        expect(token).to eq("MySessionToken123")
      end
    end

    context "with different regions" do
      it "uses the specified region in the credential scope" do
        result = signer.sign_request(**base_request, region: "eu-west-1")
        auth = result[:headers].find { |n, _| n == "Authorization" }&.last
        expect(auth).to include("/eu-west-1/sts/aws4_request")
      end
    end

    context "with query string in URI" do
      it "preserves the query string" do
        result = signer.sign_request(
          **base_request, method: "GET",
                          uri: "/?Action=GetCallerIdentity&Version=2011-06-15",
                          body: nil
        )
        expect(result[:uri]).to eq("/?Action=GetCallerIdentity&Version=2011-06-15")
      end
    end

    context "validation" do
      it "raises ArgumentError for missing region" do
        expect do
          signer.sign_request(**base_request.except(:region))
        end.to raise_error(ArgumentError, /region/)
      end

      it "raises ArgumentError for missing access_key_id" do
        expect do
          signer.sign_request(**base_request.except(:access_key_id))
        end.to raise_error(ArgumentError, /access_key_id/)
      end

      it "raises ArgumentError for missing secret_access_key" do
        expect do
          signer.sign_request(**base_request.except(:secret_access_key))
        end.to raise_error(ArgumentError, /secret_access_key/)
      end

      it "raises ArgumentError for missing method" do
        expect do
          signer.sign_request(**base_request.except(:method))
        end.to raise_error(ArgumentError, /method/)
      end

      it "raises ArgumentError for missing uri" do
        expect do
          signer.sign_request(**base_request.except(:uri))
        end.to raise_error(ArgumentError, /uri/)
      end

      it "raises ArgumentError for missing headers" do
        expect do
          signer.sign_request(**base_request.except(:headers))
        end.to raise_error(ArgumentError, /headers/)
      end

      it "raises ArgumentError for non-array headers" do
        expect do
          signer.sign_request(**base_request, headers: "bad")
        end.to raise_error(ArgumentError, /headers/)
      end
    end
  end

  describe "service-specific configurations" do
    context "S3 signing" do
      subject(:signer) do
        described_class.new(
          service: "s3",
          use_double_uri_encode: false,
          normalize_uri_path: false
        )
      end

      it "signs S3 requests with the s3 service" do
        result = signer.sign_request(
          region: region,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          method: "GET",
          uri: "/my-bucket/my%20key",
          headers: [["host", "s3.amazonaws.com"]]
        )
        auth = result[:headers].find { |n, _| n == "Authorization" }&.last
        expect(auth).to include("/s3/aws4_request")
      end
    end

    context "body signing" do
      subject(:signer) do
        described_class.new(service: "dynamodb", sign_body: true)
      end

      it "computes SHA-256 of the body" do
        body = "{}"
        expected_sha = Digest::SHA256.hexdigest(body)

        result = signer.sign_request(
          region: region,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          method: "POST",
          uri: "/",
          headers: [
            ["host", "dynamodb.us-east-1.amazonaws.com"],
            ["content-type", "application/x-amz-json-1.0"]
          ],
          body: body
        )

        sha = result[:headers].find { |n, _| n == "x-amz-content-sha256" }&.last
        expect(sha).to eq(expected_sha)
      end
    end

    context "no SHA256 header" do
      subject(:signer) do
        described_class.new(service: "execute-api", apply_sha256_header: false)
      end

      it "does not add x-amz-content-sha256 header" do
        result = signer.sign_request(
          region: region,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          method: "GET",
          uri: "/prod/resource",
          headers: [["host", "abc123.execute-api.us-east-1.amazonaws.com"]]
        )
        header_names = result[:headers].map(&:first)
        expect(header_names).not_to include("x-amz-content-sha256")
      end
    end
  end

  describe "signer reuse" do
    it "can sign multiple requests with the same signer" do
      signer = described_class.new(service: "sts")
      signatures = 3.times.map do |i|
        result = signer.sign_request(
          region: region,
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          method: "GET",
          uri: "/call-#{i}",
          headers: [["host", "sts.amazonaws.com"]]
        )
        result[:headers].find { |n, _| n == "Authorization" }&.last
      end

      # All should have valid signatures
      signatures.each do |sig|
        expect(sig).to start_with("AWS4-HMAC-SHA256")
      end

      # Different URIs should produce different signatures
      expect(signatures.uniq.length).to eq(3)
    end
  end
end
