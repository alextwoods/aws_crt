# frozen_string_literal: true

# Unit tests for AwsCrt::SignedHttpClient.
#
# Tests the combined signer + HTTP client that signs and sends
# requests in a single native call. Uses a local echo server
# to verify the full sign-and-send flow.

require "spec_helper"
require "support/test_server"

RSpec.describe AwsCrt::SignedHttpClient do
  # Test credentials (not real)
  let(:access_key_id) { "AKIAIOSFODNN7EXAMPLE" }
  let(:secret_access_key) { "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" }
  let(:region) { "us-east-1" }

  let(:credentials) do
    {
      region: region,
      access_key_id: access_key_id,
      secret_access_key: secret_access_key
    }
  end

  describe ".new" do
    it "creates a client with a service name" do
      client = described_class.new(service: "sts")
      expect(client).to be_a(described_class)
    end

    it "raises ArgumentError when service is missing" do
      expect { described_class.new }.to raise_error(ArgumentError, /service/)
    end

    it "accepts all signing and HTTP configuration options" do
      client = described_class.new(
        service: "s3",
        apply_sha256_header: false,
        use_double_uri_encode: false,
        normalize_uri_path: false,
        sign_body: true,
        max_connections: 10,
        connect_timeout_ms: 5_000,
        read_timeout_ms: 10_000,
        ssl_verify_peer: false
      )
      expect(client).to be_a(described_class)
    end
  end

  describe "#request" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    let(:client) { described_class.new(service: "sts") }

    it "signs and sends a GET request, returning an HttpResponse" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/hello", headers, nil, **credentials
      )

      expect(response).to be_a(AwsCrt::Http::Response)
      expect(response.status_code).to eq(200)
      expect(response.body).to include("GET")
      expect(response.body).to include("/hello")
      expect(response.headers).to be_a(Hash)
    end

    it "signs and sends a POST request with a body" do
      body_content = "Action=GetCallerIdentity&Version=2011-06-15"
      headers = [
        ["host", "127.0.0.1:#{server.port}"],
        ["content-type", "application/x-www-form-urlencoded"],
        ["content-length", body_content.bytesize.to_s]
      ]

      response = client.request(
        endpoint, "POST", "/", headers, body_content, **credentials
      )

      expect(response.status_code).to eq(200)
      expect(response.body).to include("POST")
      expect(response.body).to include(body_content)
    end

    it "adds SigV4 signing headers to the request" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/signed", headers, nil, **credentials
      )

      # The echo server returns the request headers in the JSON body.
      # SigV4 signing should have added Authorization and X-Amz-Date.
      expect(response.body).to include("Authorization")
      expect(response.body).to include("AWS4-HMAC-SHA256")
      expect(response.body).to include("X-Amz-Date")
    end

    it "includes x-amz-content-sha256 header by default" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/sha256", headers, nil, **credentials
      )

      expect(response.body).to include("x-amz-content-sha256")
    end

    it "includes session token when provided" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      creds_with_token = credentials.merge(session_token: "MySessionToken123")

      response = client.request(
        endpoint, "GET", "/token", headers, nil, **creds_with_token
      )

      expect(response.body).to include("X-Amz-Security-Token")
      expect(response.body).to include("MySessionToken123")
    end

    it "streams the response body when a block is given" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      chunks = []
      response = client.request(
        endpoint, "GET", "/stream", headers, nil, **credentials
      ) do |chunk|
        chunks << chunk
      end

      expect(response.status_code).to eq(200)
      expect(response.headers).to be_a(Hash)
      expect(chunks.join).to include("GET")
      expect(chunks.join).to include("/stream")
    end

    context "validation" do
      it "raises ArgumentError for missing region" do
        headers = [["host", "example.com"]]
        expect do
          client.request(endpoint, "GET", "/", headers, nil,
                         access_key_id: access_key_id,
                         secret_access_key: secret_access_key)
        end.to raise_error(ArgumentError, /region/)
      end

      it "raises ArgumentError for missing access_key_id" do
        headers = [["host", "example.com"]]
        expect do
          client.request(endpoint, "GET", "/", headers, nil,
                         region: region,
                         secret_access_key: secret_access_key)
        end.to raise_error(ArgumentError, /access_key_id/)
      end

      it "raises ArgumentError for missing secret_access_key" do
        headers = [["host", "example.com"]]
        expect do
          client.request(endpoint, "GET", "/", headers, nil,
                         region: region,
                         access_key_id: access_key_id)
        end.to raise_error(ArgumentError, /secret_access_key/)
      end

      it "raises ArgumentError for non-array headers" do
        expect do
          client.request(endpoint, "GET", "/", "bad", nil, **credentials)
        end.to raise_error(ArgumentError, /headers/)
      end

      it "raises ArgumentError for invalid endpoints" do
        headers = [["host", "example.com"]]
        expect do
          client.request("not-a-url", "GET", "/", headers, nil, **credentials)
        end.to raise_error(ArgumentError, /Invalid endpoint/)
      end
    end
  end

  describe "frozen client" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    it "can make requests when frozen" do
      client = described_class.new(service: "sts")
      client.freeze

      headers = [["host", "127.0.0.1:#{server.port}"]]
      response = client.request(
        endpoint, "GET", "/frozen", headers, nil, **credentials
      )

      expect(response.status_code).to eq(200)
      expect(response.body).to include("/frozen")
    end
  end

  describe "Ractor.shareable?" do
    it "is shareable when frozen" do
      client = described_class.new(service: "sts")
      client.freeze
      expect(Ractor.shareable?(client)).to be true
    end

    it "is not shareable when not frozen" do
      client = described_class.new(service: "sts")
      expect(Ractor.shareable?(client)).to be false
    end
  end

  describe "service-specific configurations" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    context "S3-style signing" do
      it "signs with the s3 service" do
        client = described_class.new(
          service: "s3",
          use_double_uri_encode: false,
          normalize_uri_path: false
        )
        headers = [["host", "127.0.0.1:#{server.port}"]]

        response = client.request(
          endpoint, "GET", "/my-bucket/my-key", headers, nil, **credentials
        )

        expect(response.body).to include("Authorization")
        expect(response.body).to include("/s3/aws4_request")
      end
    end
  end

  describe "thread safety" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    it "handles concurrent requests from multiple threads" do
      client = described_class.new(service: "sts")
      results = Array.new(8)

      threads = 8.times.map do |i|
        Thread.new do
          headers = [["host", "127.0.0.1:#{server.port}"]]
          response = client.request(
            endpoint, "GET", "/thread-#{i}", headers, nil, **credentials
          )
          results[i] = [response.status_code, response.body]
        end
      end
      threads.each(&:join)

      results.each_with_index do |(status, body), i|
        expect(status).to eq(200)
        expect(body).to include("/thread-#{i}")
      end
    end
  end

  describe "endpoint pool reuse" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    it "reuses the same internal pool for repeated requests" do
      client = described_class.new(service: "sts")
      headers = [["host", "127.0.0.1:#{server.port}"]]

      r1 = client.request(endpoint, "GET", "/first", headers, nil, **credentials)
      r2 = client.request(endpoint, "GET", "/second", headers, nil, **credentials)

      expect(r1.status_code).to eq(200)
      expect(r2.status_code).to eq(200)
    end
  end

  describe "client reuse" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    it "can sign multiple requests with different credentials" do
      client = described_class.new(service: "sts")
      headers = [["host", "127.0.0.1:#{server.port}"]]

      # First request with one set of credentials
      r1 = client.request(
        endpoint, "GET", "/call-1", headers, nil, **credentials
      )

      # Second request with different credentials
      other_creds = credentials.merge(
        access_key_id: "AKIAOTHER7EXAMPLE",
        secret_access_key: "otherSecretKey123"
      )
      r2 = client.request(
        endpoint, "GET", "/call-2", headers, nil, **other_creds
      )

      expect(r1.status_code).to eq(200)
      expect(r2.status_code).to eq(200)
      expect(r1.body).to include("/call-1")
      expect(r2.body).to include("/call-2")

      # Different credentials should produce different Authorization headers
      auth1 = r1.body[/Authorization.*?(?=\\"|$)/]
      auth2 = r2.body[/Authorization.*?(?=\\"|$)/]
      expect(auth1).not_to eq(auth2)
    end
  end

  describe "streaming_io" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    let(:client) { described_class.new(service: "sts") }

    it "returns a SharableStringIO body when streaming_io: true" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/streaming-io", headers, nil,
        **credentials, streaming_io: true
      )

      expect(response.status_code).to eq(200)
      expect(response.body).to be_a(AwsCrt::Http::SharableStringIO)
      expect(response.body.read).to include("/streaming-io")
    end

    it "returns a frozen, Ractor-shareable SharableStringIO" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/sio-frozen", headers, nil,
        **credentials, streaming_io: true
      )

      sio = response.body
      expect(sio).to be_frozen
      expect(Ractor.shareable?(sio)).to be true
    end

    it "raises ArgumentError when streaming_io and block are both given" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      expect {
        client.request(
          endpoint, "GET", "/test", headers, nil,
          **credentials, streaming_io: true
        ) { |_chunk| }
      }.to raise_error(ArgumentError, "streaming_io and block are mutually exclusive")
    end
  end

  describe "on_data" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    let(:client) { described_class.new(service: "sts") }

    it "calls on_data listeners with the response body in buffered mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received = []
      listener = ->(chunk) { received << chunk }

      response = client.request(
        endpoint, "GET", "/on-data-test", headers, nil,
        **credentials, on_data: [listener]
      )

      expect(response.status_code).to eq(200)
      expect(received.join).to include("/on-data-test")
    end

    it "calls on_data listeners in streaming_io mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received = []
      listener = ->(chunk) { received << chunk }

      response = client.request(
        endpoint, "GET", "/on-data-sio", headers, nil,
        **credentials, streaming_io: true, on_data: [listener]
      )

      expect(response.status_code).to eq(200)
      expect(received.join).to include("/on-data-sio")
    end

    it "calls on_data listeners for each chunk in block mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      block_chunks = []
      listener_chunks = []
      listener = ->(chunk) { listener_chunks << chunk }

      client.request(
        endpoint, "GET", "/on-data-block", headers, nil,
        **credentials, on_data: [listener]
      ) { |chunk| block_chunks << chunk }

      expect(block_chunks.join).to include("/on-data-block")
      expect(listener_chunks.join).to include("/on-data-block")
    end

    it "calls multiple on_data listeners" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received1 = []
      received2 = []
      listener1 = ->(chunk) { received1 << chunk }
      listener2 = ->(chunk) { received2 << chunk }

      client.request(
        endpoint, "GET", "/multi-listener", headers, nil,
        **credentials, on_data: [listener1, listener2]
      )

      expect(received1.join).to include("/multi-listener")
      expect(received2.join).to include("/multi-listener")
    end
  end

  describe "on_headers" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    let(:client) { described_class.new(service: "sts") }

    it "calls on_headers listeners with (status, headers_hash) in buffered mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received = []
      listener = ->(status, hdrs) { received << [status, hdrs] }

      response = client.request(
        endpoint, "GET", "/on-headers-test", headers, nil,
        **credentials, on_headers: [listener]
      )

      expect(response.status_code).to eq(200)
      expect(received.length).to eq(1)
      expect(received[0][0]).to eq(200)
      expect(received[0][1]).to be_a(Hash)
      expect(received[0][1]).to have_key("Content-Type")
    end

    it "calls on_headers listeners in streaming_io mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received = []
      listener = ->(status, hdrs) { received << [status, hdrs] }

      response = client.request(
        endpoint, "GET", "/on-headers-sio", headers, nil,
        **credentials, streaming_io: true, on_headers: [listener]
      )

      expect(response.status_code).to eq(200)
      expect(received.length).to eq(1)
      expect(received[0][0]).to eq(200)
      expect(received[0][1]).to be_a(Hash)
    end

    it "calls on_headers listeners in block mode" do
      headers = [["host", "127.0.0.1:#{server.port}"]]
      received = []
      listener = ->(status, hdrs) { received << [status, hdrs] }

      client.request(
        endpoint, "GET", "/on-headers-block", headers, nil,
        **credentials, on_headers: [listener]
      ) { |_chunk| }

      expect(received.length).to eq(1)
      expect(received[0][0]).to eq(200)
      expect(received[0][1]).to be_a(Hash)
    end
  end

  describe "checksum_algorithms" do
    let(:server) { TestServer.start }
    let(:endpoint) { server.endpoint }

    after { server.stop }

    let(:client) { described_class.new(service: "sts") }

    it "computes CRC32 checksum when the response has the matching header" do
      headers = [
        ["host", "127.0.0.1:#{server.port}"],
        ["X-Add-Checksum", "CRC32"]
      ]

      response = client.request(
        endpoint, "GET", "/checksum-crc32", headers, nil,
        **credentials, checksum_algorithms: ["CRC32"]
      )

      expect(response.status_code).to eq(200)
      expect(response.checksum_algorithm).to eq("CRC32")
      expect(response.computed_checksum).not_to be_nil
    end

    it "computes SHA256 checksum when the response has the matching header" do
      headers = [
        ["host", "127.0.0.1:#{server.port}"],
        ["X-Add-Checksum", "SHA256"]
      ]

      response = client.request(
        endpoint, "GET", "/checksum-sha256", headers, nil,
        **credentials, checksum_algorithms: ["SHA256"]
      )

      expect(response.status_code).to eq(200)
      expect(response.checksum_algorithm).to eq("SHA256")
      expect(response.computed_checksum).not_to be_nil
    end

    it "computes checksum in streaming_io mode" do
      headers = [
        ["host", "127.0.0.1:#{server.port}"],
        ["X-Add-Checksum", "CRC32"]
      ]

      response = client.request(
        endpoint, "GET", "/checksum-sio", headers, nil,
        **credentials, streaming_io: true, checksum_algorithms: ["CRC32"]
      )

      expect(response.status_code).to eq(200)
      expect(response.checksum_algorithm).to eq("CRC32")
      expect(response.computed_checksum).not_to be_nil
    end

    it "returns nil checksum when no matching header is present" do
      headers = [["host", "127.0.0.1:#{server.port}"]]

      response = client.request(
        endpoint, "GET", "/no-checksum", headers, nil,
        **credentials, checksum_algorithms: ["CRC32"]
      )

      expect(response.status_code).to eq(200)
      expect(response.checksum_algorithm).to be_nil
      expect(response.computed_checksum).to be_nil
    end
  end
end
