# frozen_string_literal: true

# Integration tests for response checksum computation.
#
# Tests that when `checksum_algorithms:` is passed and the response
# contains a matching `x-amz-checksum-*` header, the client computes
# the checksum over the response body and populates `checksum_algorithm`
# and `computed_checksum` on the HttpResponse.

require "json"
require "base64"
require "zlib"
require "digest"
require "support/test_server"

RSpec.describe "Response checksum computation" do
  before(:all) do
    @server = TestServer.start
    @client = AwsCrt::Http::Client.new
  end

  after(:all) do
    @server&.stop
  end

  def host_header
    ["Host", "127.0.0.1:#{@server.port}"]
  end

  def request_with_checksum(algorithm, path: "/test")
    headers = [host_header, ["X-Add-Checksum", algorithm]]
    @client.request(
      @server.endpoint, "GET", path, headers,
      checksum_algorithms: [algorithm]
    )
  end

  describe "CRC32 checksum" do
    it "computes CRC32 when the response has x-amz-checksum-crc32 header" do
      response = request_with_checksum("CRC32")

      expect(response.checksum_algorithm).to eq("CRC32")
      expect(response.computed_checksum).not_to be_nil

      # Verify the computed checksum matches what we'd compute in Ruby
      expected_crc = Zlib.crc32(response.body)
      expected_b64 = Base64.strict_encode64([expected_crc].pack("N"))
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "CRC32C checksum" do
    it "computes CRC32C when the response has x-amz-checksum-crc32c header" do
      response = request_with_checksum("CRC32C")

      expect(response.checksum_algorithm).to eq("CRC32C")
      expect(response.computed_checksum).not_to be_nil

      # Verify using the CRT's own CRC32C function
      expected_crc = AwsCrt::Checksums.crc32c(response.body)
      expected_b64 = Base64.strict_encode64([expected_crc].pack("N"))
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "CRC64NVME checksum" do
    it "computes CRC64NVME when the response has x-amz-checksum-crc64nvme header" do
      response = request_with_checksum("CRC64NVME")

      expect(response.checksum_algorithm).to eq("CRC64NVME")
      expect(response.computed_checksum).not_to be_nil

      # Verify using the CRT's own CRC64NVME function
      expected_crc = AwsCrt::Checksums.crc64nvme(response.body)
      expected_b64 = Base64.strict_encode64([expected_crc].pack("Q>"))
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "SHA256 checksum" do
    it "computes SHA256 when the response has x-amz-checksum-sha256 header" do
      response = request_with_checksum("SHA256")

      expect(response.checksum_algorithm).to eq("SHA256")
      expect(response.computed_checksum).not_to be_nil

      # Verify using Ruby's Digest::SHA256
      expected_digest = Digest::SHA256.digest(response.body)
      expected_b64 = Base64.strict_encode64(expected_digest)
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "SHA1 checksum" do
    it "computes SHA1 when the response has x-amz-checksum-sha1 header" do
      response = request_with_checksum("SHA1")

      expect(response.checksum_algorithm).to eq("SHA1")
      expect(response.computed_checksum).not_to be_nil

      # Verify using Ruby's Digest::SHA1
      expected_digest = Digest::SHA1.digest(response.body)
      expected_b64 = Base64.strict_encode64(expected_digest)
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "no matching header" do
    it "returns nil checksum fields when no matching header exists" do
      # Request with CRC32 algorithm but server doesn't add the header
      response = @client.request(
        @server.endpoint, "GET", "/test", [host_header],
        checksum_algorithms: ["CRC32"]
      )

      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end
  end

  describe "nil/empty checksum_algorithms" do
    it "returns nil checksum fields when checksum_algorithms is nil" do
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers,
        checksum_algorithms: nil
      )

      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end

    it "returns nil checksum fields when checksum_algorithms is empty" do
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers,
        checksum_algorithms: []
      )

      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end

    it "returns nil checksum fields when checksum_algorithms is not provided" do
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers
      )

      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end
  end

  describe "priority ordering" do
    it "uses the first matching algorithm from the priority list" do
      # Server adds CRC32 header, but we list SHA256 first (which won't match)
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers,
        checksum_algorithms: ["SHA256", "CRC32"]
      )

      # SHA256 header doesn't exist, so CRC32 should be used
      expect(response.checksum_algorithm).to eq("CRC32")
    end
  end

  describe "streaming_io path" do
    it "computes checksum in streaming_io mode" do
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers,
        streaming_io: true, checksum_algorithms: ["CRC32"]
      )

      expect(response.checksum_algorithm).to eq("CRC32")
      expect(response.computed_checksum).not_to be_nil

      # Verify the checksum matches the body content
      body_content = response.body.read
      expected_crc = Zlib.crc32(body_content)
      expected_b64 = Base64.strict_encode64([expected_crc].pack("N"))
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end

  describe "block streaming path" do
    it "returns nil checksum fields in block streaming mode" do
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/test", headers,
        checksum_algorithms: ["CRC32"]
      ) { |_chunk| }

      # Block path doesn't compute checksums natively
      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end
  end

  describe "large body checksum" do
    it "correctly computes checksum for a 64KB body" do
      body_size = 64 * 1024
      headers = [host_header, ["X-Add-Checksum", "CRC32"]]
      response = @client.request(
        @server.endpoint, "GET", "/large?body_size=#{body_size}", headers,
        checksum_algorithms: ["CRC32"]
      )

      expect(response.checksum_algorithm).to eq("CRC32")
      expected_crc = Zlib.crc32(response.body)
      expected_b64 = Base64.strict_encode64([expected_crc].pack("N"))
      expect(response.computed_checksum).to eq(expected_b64)
    end
  end
end
