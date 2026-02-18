# frozen_string_literal: true

require "aws_crt/s3/client"
require "stringio"

# Unit tests for AwsCrt::S3::Client.
#
# These tests focus on Ruby-level validation and response handling logic
# that runs before or after the Rust native extension calls.
#
# Requirements: 3.1 — WHEN an S3_Client is created with a region and credentials,
#   THE Rust_Extension SHALL initialize a CRT S3 client.
# Requirements: 4.1 — WHEN get_object is called with a bucket and key,
#   THE S3_Client SHALL execute a CRT meta-request of type GET_OBJECT.
# Requirements: 5.1 — WHEN put_object is called with a bucket, key, and a String body,
#   THE S3_Client SHALL execute a CRT meta-request of type PUT_OBJECT.
# Requirements: 5.6 — WHEN put_object is called with a checksum_algorithm parameter
#   (CRC32, CRC32C, SHA1, or SHA256), THE S3_Client SHALL configure the CRT
#   meta-request to compute and include the specified checksum.

RSpec.describe AwsCrt::S3::Client do
  describe "VALID_CHECKSUM_ALGORITHMS" do
    it "contains exactly the four supported algorithms" do
      expect(described_class::VALID_CHECKSUM_ALGORITHMS).to eq(%w[CRC32 CRC32C SHA1 SHA256])
    end

    it "is frozen" do
      expect(described_class::VALID_CHECKSUM_ALGORITHMS).to be_frozen
    end
  end

  describe "#initialize — required option validation" do
    it "raises ArgumentError when :region is missing" do
      expect do
        described_class.new(
          access_key_id: "AKID",
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :region/)
    end

    it "raises ArgumentError when :region is nil" do
      expect do
        described_class.new(
          region: nil,
          access_key_id: "AKID",
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :region/)
    end

    it "raises ArgumentError when :region is an empty string" do
      expect do
        described_class.new(
          region: "",
          access_key_id: "AKID",
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :region/)
    end

    it "raises ArgumentError when :access_key_id is missing" do
      expect do
        described_class.new(
          region: "us-east-1",
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :access_key_id/)
    end

    it "raises ArgumentError when :access_key_id is nil" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: nil,
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :access_key_id/)
    end

    it "raises ArgumentError when :access_key_id is an empty string" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: "",
          secret_access_key: "secret"
        )
      end.to raise_error(ArgumentError, /missing required option :access_key_id/)
    end

    it "raises ArgumentError when :secret_access_key is missing" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: "AKID"
        )
      end.to raise_error(ArgumentError, /missing required option :secret_access_key/)
    end

    it "raises ArgumentError when :secret_access_key is nil" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: "AKID",
          secret_access_key: nil
        )
      end.to raise_error(ArgumentError, /missing required option :secret_access_key/)
    end

    it "raises ArgumentError when :secret_access_key is an empty string" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: "AKID",
          secret_access_key: ""
        )
      end.to raise_error(ArgumentError, /missing required option :secret_access_key/)
    end

    it "raises ArgumentError for the first missing option when multiple are absent" do
      expect do
        described_class.new({})
      end.to raise_error(ArgumentError, /missing required option :region/)
    end
  end

  describe "#initialize — credential resolution" do
    before do
      allow_any_instance_of(described_class).to receive(:_native_initialize)
    end

    it "accepts a credential provider (responds to #credentials)" do
      creds = AwsCrt::S3::Credentials.new(
        access_key_id: "AKID",
        secret_access_key: "secret"
      )
      provider = AwsCrt::S3::StaticCredentialProvider.new(creds)

      expect do
        described_class.new(region: "us-east-1", credentials: provider)
      end.not_to raise_error
    end

    it "accepts a credentials object (responds to #access_key_id)" do
      creds = AwsCrt::S3::Credentials.new(
        access_key_id: "AKID",
        secret_access_key: "secret",
        session_token: "token"
      )

      expect do
        described_class.new(region: "us-east-1", credentials: creds)
      end.not_to raise_error
    end

    it "accepts legacy access_key_id/secret_access_key strings" do
      expect do
        described_class.new(
          region: "us-east-1",
          access_key_id: "AKID",
          secret_access_key: "secret"
        )
      end.not_to raise_error
    end

    it "raises ArgumentError when :credentials does not respond to #credentials or #access_key_id" do
      expect do
        described_class.new(region: "us-east-1", credentials: "not-a-provider")
      end.to raise_error(ArgumentError, /must respond to/)
    end

    it "raises ArgumentError when no credentials are provided at all" do
      expect do
        described_class.new(region: "us-east-1")
      end.to raise_error(ArgumentError, /missing credentials/)
    end

    it "passes initial credentials from the provider to the native initializer" do
      creds = AwsCrt::S3::Credentials.new(
        access_key_id: "AKID_FROM_PROVIDER",
        secret_access_key: "SECRET_FROM_PROVIDER",
        session_token: "TOKEN_FROM_PROVIDER"
      )
      provider = AwsCrt::S3::StaticCredentialProvider.new(creds)

      expect_any_instance_of(described_class).to receive(:_native_initialize) do |_instance, opts|
        expect(opts[:access_key_id]).to eq("AKID_FROM_PROVIDER")
        expect(opts[:secret_access_key]).to eq("SECRET_FROM_PROVIDER")
        expect(opts[:session_token]).to eq("TOKEN_FROM_PROVIDER")
      end

      described_class.new(region: "us-east-1", credentials: provider)
    end

    it "resolves fresh credentials on each get_object call" do
      call_count = 0
      rotating_provider = Object.new
      rotating_provider.define_singleton_method(:credentials) do
        call_count += 1
        AwsCrt::S3::Credentials.new(
          access_key_id: "AKID_#{call_count}",
          secret_access_key: "SECRET_#{call_count}"
        )
      end

      client = described_class.new(region: "us-east-1", credentials: rotating_provider)

      success_result = { status_code: 200, headers: {}, body: "ok", checksum_validated: nil }
      allow(client).to receive(:_native_get_object) do |params|
        # Verify the injected credentials change per call
        expect(params[:_access_key_id]).to eq("AKID_#{call_count}")
        success_result
      end

      client.get_object(bucket: "b", key: "k")
      client.get_object(bucket: "b", key: "k")
      # call_count is 1 (initial) + 2 (two get_object calls) = 3
      expect(call_count).to eq(3)
    end

    it "resolves fresh credentials on each put_object call" do
      call_count = 0
      rotating_provider = Object.new
      rotating_provider.define_singleton_method(:credentials) do
        call_count += 1
        AwsCrt::S3::Credentials.new(
          access_key_id: "AKID_#{call_count}",
          secret_access_key: "SECRET_#{call_count}"
        )
      end

      client = described_class.new(region: "us-east-1", credentials: rotating_provider)

      success_result = { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      allow(client).to receive(:_native_put_object) do |params|
        expect(params[:_access_key_id]).to eq("AKID_#{call_count}")
        success_result
      end

      client.put_object(bucket: "b", key: "k", body: "data")
      client.put_object(bucket: "b", key: "k", body: "data")
      expect(call_count).to eq(3)
    end

    it "prefers :credentials over legacy access_key_id/secret_access_key" do
      creds = AwsCrt::S3::Credentials.new(
        access_key_id: "PROVIDER_AKID",
        secret_access_key: "PROVIDER_SECRET"
      )

      expect_any_instance_of(described_class).to receive(:_native_initialize) do |_instance, opts|
        expect(opts[:access_key_id]).to eq("PROVIDER_AKID")
      end

      described_class.new(
        region: "us-east-1",
        credentials: creds,
        access_key_id: "LEGACY_AKID",
        secret_access_key: "LEGACY_SECRET"
      )
    end
  end

  # For tests that exercise post-validation logic (checksum validation,
  # response handling, error translation), we stub the native Rust methods
  # so we can test the Ruby layer in isolation.
  describe "with stubbed native methods" do
    let(:client) do
      # Stub _native_initialize to avoid needing real CRT credentials.
      allow_any_instance_of(described_class).to receive(:_native_initialize)
      described_class.new(
        region: "us-east-1",
        access_key_id: "AKID",
        secret_access_key: "secret"
      )
    end

    describe "#put_object — checksum_algorithm validation" do
      %w[CRC32 CRC32C SHA1 SHA256].each do |algo|
        it "accepts valid checksum_algorithm '#{algo}'" do
          success_result = {
            status_code: 200,
            headers: {},
            body: nil,
            checksum_validated: nil
          }
          allow(client).to receive(:_native_put_object).and_return(success_result)

          response = client.put_object(
            bucket: "test-bucket",
            key: "test-key",
            body: "data",
            checksum_algorithm: algo
          )
          expect(response).to be_a(AwsCrt::S3::Response)
          expect(response.status_code).to eq(200)
        end
      end

      it "raises ArgumentError for an invalid checksum_algorithm" do
        expect do
          client.put_object(
            bucket: "test-bucket",
            key: "test-key",
            body: "data",
            checksum_algorithm: "MD5"
          )
        end.to raise_error(ArgumentError, /invalid checksum_algorithm 'MD5'/)
      end

      it "raises ArgumentError for a lowercase valid algorithm name" do
        expect do
          client.put_object(
            bucket: "test-bucket",
            key: "test-key",
            body: "data",
            checksum_algorithm: "crc32"
          )
        end.to raise_error(ArgumentError, /invalid checksum_algorithm 'crc32'/)
      end

      it "raises ArgumentError for an empty string checksum_algorithm" do
        expect do
          client.put_object(
            bucket: "test-bucket",
            key: "test-key",
            body: "data",
            checksum_algorithm: ""
          )
        end.to raise_error(ArgumentError, /invalid checksum_algorithm ''/)
      end

      it "does not validate when checksum_algorithm is not provided" do
        success_result = {
          status_code: 200,
          headers: {},
          body: nil,
          checksum_validated: nil
        }
        allow(client).to receive(:_native_put_object).and_return(success_result)

        response = client.put_object(
          bucket: "test-bucket",
          key: "test-key",
          body: "data"
        )
        expect(response).to be_a(AwsCrt::S3::Response)
      end

      it "includes the valid algorithms in the error message" do
        expect do
          client.put_object(
            bucket: "test-bucket",
            key: "test-key",
            body: "data",
            checksum_algorithm: "INVALID"
          )
        end.to raise_error(ArgumentError, /must be CRC32, CRC32C, SHA1, or SHA256/)
      end
    end

    describe "#put_object — response building" do
      it "returns a Response with status_code and headers" do
        result = {
          status_code: 200,
          headers: { "etag" => '"abc123"', "x-amz-request-id" => "req-1" },
          body: nil,
          checksum_validated: nil
        }
        allow(client).to receive(:_native_put_object).and_return(result)

        response = client.put_object(bucket: "b", key: "k", body: "data")
        expect(response.status_code).to eq(200)
        expect(response.headers).to eq({ "etag" => '"abc123"', "x-amz-request-id" => "req-1" })
        expect(response.body).to be_nil
      end
    end

    describe "#put_object — error translation" do
      it "raises ServiceError for HTTP error responses" do
        error_result = {
          error: true,
          error_code: 0,
          status_code: 404,
          headers: { "content-type" => "application/xml" },
          body: "<Error><Code>NoSuchKey</Code></Error>"
        }
        allow(client).to receive(:_native_put_object).and_return(error_result)

        expect do
          client.put_object(bucket: "b", key: "k", body: "data")
        end.to raise_error(AwsCrt::S3::ServiceError) { |e|
          expect(e.status_code).to eq(404)
          expect(e.headers).to eq({ "content-type" => "application/xml" })
          expect(e.error_body).to eq("<Error><Code>NoSuchKey</Code></Error>")
        }
      end

      it "raises NetworkError for CRT-level errors" do
        error_result = {
          error: true,
          error_code: 1029,
          status_code: 0,
          headers: {},
          body: "DNS resolution failed"
        }
        allow(client).to receive(:_native_put_object).and_return(error_result)

        expect do
          client.put_object(bucket: "b", key: "k", body: "data")
        end.to raise_error(AwsCrt::S3::NetworkError, /DNS resolution failed/)
      end
    end

    describe "#put_object — IO tempfile spilling" do
      let(:success_result) do
        { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
      end

      it "spills large IO bodies to a tempfile and passes a File to the native method" do
        large_body = StringIO.new("x" * (16 * 1024 * 1024)) # exactly 16 MB

        allow(client).to receive(:_native_put_object) do |params|
          # The IO should have been replaced with a File (tempfile)
          expect(params[:body]).to be_a(File)
          expect(File.read(params[:body].path)).to eq("x" * (16 * 1024 * 1024))
          success_result
        end

        client.put_object(bucket: "b", key: "k", body: large_body)
      end

      it "passes small IO bodies through unchanged" do
        small_body = StringIO.new("small data")

        allow(client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to be(small_body)
          success_result
        end

        client.put_object(bucket: "b", key: "k", body: small_body)
      end

      it "passes IO bodies without a size method through unchanged" do
        io_without_size = Object.new
        io_without_size.define_singleton_method(:read) { "data" }

        allow(client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to be(io_without_size)
          success_result
        end

        client.put_object(bucket: "b", key: "k", body: io_without_size)
      end

      it "passes String bodies through unchanged" do
        allow(client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to eq("string body")
          success_result
        end

        client.put_object(bucket: "b", key: "k", body: "string body")
      end

      it "passes File bodies through unchanged" do
        tempfile = Tempfile.new("test-file")
        tempfile.write("file data")
        tempfile.close
        file = File.open(tempfile.path, "rb")

        allow(client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to be(file)
          success_result
        end

        begin
          client.put_object(bucket: "b", key: "k", body: file)
        ensure
          file.close
          tempfile.unlink
        end
      end

      it "cleans up the tempfile after a successful upload" do
        large_body = StringIO.new("x" * (16 * 1024 * 1024))
        tempfile_path = nil

        allow(client).to receive(:_native_put_object) do |params|
          tempfile_path = params[:body].path
          expect(File.exist?(tempfile_path)).to be true
          success_result
        end

        client.put_object(bucket: "b", key: "k", body: large_body)
        expect(File.exist?(tempfile_path)).to be false
      end

      it "cleans up the tempfile when the native method raises" do
        large_body = StringIO.new("x" * (16 * 1024 * 1024))
        tempfile_path = nil

        allow(client).to receive(:_native_put_object) do |params|
          tempfile_path = params[:body].path
          raise "simulated error"
        end

        expect do
          client.put_object(bucket: "b", key: "k", body: large_body)
        end.to raise_error(RuntimeError, "simulated error")

        expect(File.exist?(tempfile_path)).to be false
      end

      it "respects a custom io_tempfile_threshold" do
        allow_any_instance_of(described_class).to receive(:_native_initialize)
        custom_client = described_class.new(
          region: "us-east-1",
          access_key_id: "AKID",
          secret_access_key: "secret",
          io_tempfile_threshold: 100
        )

        # 100 bytes — exactly at threshold, should spill
        body = StringIO.new("x" * 100)

        allow(custom_client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to be_a(File)
          success_result
        end

        custom_client.put_object(bucket: "b", key: "k", body: body)
      end

      it "does not spill IO bodies below the custom threshold" do
        allow_any_instance_of(described_class).to receive(:_native_initialize)
        custom_client = described_class.new(
          region: "us-east-1",
          access_key_id: "AKID",
          secret_access_key: "secret",
          io_tempfile_threshold: 100
        )

        body = StringIO.new("x" * 99)

        allow(custom_client).to receive(:_native_put_object) do |params|
          expect(params[:body]).to be(body)
          success_result
        end

        custom_client.put_object(bucket: "b", key: "k", body: body)
      end
    end

    describe "#get_object — response handling modes" do
      let(:success_result) do
        {
          status_code: 200,
          headers: { "content-type" => "text/plain" },
          body: "hello world",
          checksum_validated: nil
        }
      end

      it "returns buffered body when no response_target or block" do
        allow(client).to receive(:_native_get_object).and_return(success_result)

        response = client.get_object(bucket: "b", key: "k")
        expect(response.body).to eq("hello world")
        expect(response.status_code).to eq(200)
      end

      it "streams tempfile to IO response_target without buffering entire body" do
        # When response_target is an IO, the client creates a tempfile,
        # passes its path to the CRT (recv_filepath), then streams the
        # tempfile contents to the IO in chunks.
        allow(client).to receive(:_native_get_object) do |params|
          # The IO should have been replaced with a tempfile path string
          expect(params[:response_target]).to be_a(String)
          # Simulate CRT writing to the tempfile
          File.write(params[:response_target], "hello world")
          { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
        end

        io = StringIO.new
        response = client.get_object(bucket: "b", key: "k", response_target: io)
        expect(io.string).to eq("hello world")
        expect(response.body).to be_nil
      end

      it "does not write to response_target when it is a String (file path)" do
        # When response_target is a String, the CRT handles file I/O directly.
        # The Ruby layer should pass the body through as-is (recv_filepath mode
        # means body is typically nil from Rust, but if present, it's kept).
        file_path_result = {
          status_code: 200,
          headers: {},
          body: nil,
          checksum_validated: nil
        }
        allow(client).to receive(:_native_get_object).and_return(file_path_result)

        response = client.get_object(bucket: "b", key: "k", response_target: "/tmp/test")
        expect(response.body).to be_nil
      end

      it "converts a File response_target to its path for CRT direct file I/O" do
        allow(client).to receive(:_native_get_object) do |params|
          # The File should have been converted to its path string
          expect(params[:response_target]).to be_a(String)
          expect(params[:response_target]).to eq("/tmp/fake_file")
          { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
        end

        file = instance_double(File, path: "/tmp/fake_file")
        allow(file).to receive(:is_a?).with(File).and_return(true)
        allow(file).to receive(:is_a?).with(String).and_return(false)

        response = client.get_object(bucket: "b", key: "k", response_target: file)
        expect(response.body).to be_nil
      end

      it "cleans up the tempfile after streaming to an IO target" do
        tempfile_path = nil
        allow(client).to receive(:_native_get_object) do |params|
          tempfile_path = params[:response_target]
          File.write(tempfile_path, "data")
          { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
        end

        io = StringIO.new
        client.get_object(bucket: "b", key: "k", response_target: io)
        expect(File.exist?(tempfile_path)).to be false
      end

      it "yields body to block via tempfile streaming and sets body to nil" do
        allow(client).to receive(:_native_get_object) do |params|
          # Block streaming now routes through a tempfile — the CRT writes
          # to the tempfile path via recv_filepath, then Ruby streams chunks.
          expect(params[:response_target]).to be_a(String)
          File.write(params[:response_target], "hello world")
          { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
        end
        chunks = []

        response = client.get_object(bucket: "b", key: "k") { |chunk| chunks << chunk }
        expect(chunks.join).to eq("hello world")
        expect(response.body).to be_nil
      end

      it "cleans up the tempfile after block streaming" do
        tempfile_path = nil
        allow(client).to receive(:_native_get_object) do |params|
          tempfile_path = params[:response_target]
          File.write(tempfile_path, "data")
          { status_code: 200, headers: {}, body: nil, checksum_validated: nil }
        end

        client.get_object(bucket: "b", key: "k") { |_chunk| nil }
        expect(File.exist?(tempfile_path)).to be false
      end

      it "returns body with checksum_validated when present" do
        result_with_checksum = success_result.merge(checksum_validated: "CRC32")
        allow(client).to receive(:_native_get_object).and_return(result_with_checksum)

        response = client.get_object(bucket: "b", key: "k")
        expect(response.checksum_validated).to eq("CRC32")
      end
    end

    describe "#get_object — error translation" do
      it "raises ServiceError for HTTP error responses" do
        error_result = {
          error: true,
          error_code: 0,
          status_code: 403,
          headers: { "content-type" => "application/xml" },
          body: "<Error><Code>AccessDenied</Code></Error>"
        }
        allow(client).to receive(:_native_get_object).and_return(error_result)

        expect do
          client.get_object(bucket: "b", key: "k")
        end.to raise_error(AwsCrt::S3::ServiceError) { |e|
          expect(e.status_code).to eq(403)
          expect(e.error_body).to eq("<Error><Code>AccessDenied</Code></Error>")
        }
      end

      it "raises NetworkError for CRT-level errors" do
        error_result = {
          error: true,
          error_code: 1029,
          status_code: 0,
          headers: nil,
          body: ""
        }
        allow(client).to receive(:_native_get_object).and_return(error_result)

        expect do
          client.get_object(bucket: "b", key: "k")
        end.to raise_error(AwsCrt::S3::NetworkError)
      end
    end
  end
end
