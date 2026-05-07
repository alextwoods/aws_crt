# frozen_string_literal: true

module AwsCrt
  # Combined SigV4 signer and HTTP client.
  #
  # Signs and sends HTTP requests in a single native call, avoiding the
  # overhead of crossing the Ruby/Rust boundary twice. The CRT HTTP message
  # is built once, signed in-place, and sent directly — no intermediate
  # conversion back to Ruby types between signing and sending.
  #
  # Use this class when you know you need to both sign and send a request.
  # For signing-only or sending-only use cases, use {Sigv4Signer} and
  # {Http::Client} independently.
  #
  # The client is frozen and Ractor-shareable after construction, managing
  # connection pools internally (same pattern as {Http::Client}).
  #
  # @example Basic usage
  #   client = AwsCrt::SignedHttpClient.new(
  #     service: 'sts',
  #     ssl_verify_peer: true
  #   )
  #   client.freeze
  #
  #   status, headers, body = client.request(
  #     'https://sts.us-east-1.amazonaws.com',
  #     'POST', '/',
  #     [['host', 'sts.us-east-1.amazonaws.com'],
  #      ['content-type', 'application/x-www-form-urlencoded']],
  #     'Action=GetCallerIdentity&Version=2011-06-15',
  #     region: 'us-east-1',
  #     access_key_id: 'AKIA...',
  #     secret_access_key: 'secret'
  #   )
  #
  # @example S3-style signing
  #   client = AwsCrt::SignedHttpClient.new(
  #     service: 's3',
  #     use_double_uri_encode: false,
  #     normalize_uri_path: false,
  #     max_connections: 50
  #   )
  #   client.freeze
  #
  # @example Streaming response
  #   client.request(
  #     endpoint, 'GET', '/large-file',
  #     [['host', 'example.com']],
  #     nil,
  #     region: 'us-east-1',
  #     access_key_id: creds.access_key_id,
  #     secret_access_key: creds.secret_access_key,
  #     session_token: creds.session_token
  #   ) do |chunk|
  #     io.write(chunk)
  #   end
  #
  class SignedHttpClient
    # Alias the Rust-defined methods so we can wrap them with Ruby logic.
    alias _native_initialize initialize
    alias _native_request request

    # @param [Hash] options
    #
    # Signing options:
    # @option options [String] :service (required) AWS service name
    #   (e.g. "s3", "sts", "dynamodb", "execute-api")
    # @option options [Boolean] :apply_sha256_header (true)
    #   Whether to add the x-amz-content-sha256 header
    # @option options [Boolean] :use_double_uri_encode (true)
    #   Whether to double-encode the URI path. Set to false for S3.
    # @option options [Boolean] :normalize_uri_path (true)
    #   Whether to normalize the URI path (remove . and ..)
    # @option options [Boolean] :sign_body (false)
    #   Whether to compute SHA-256 of the body. When false, uses
    #   UNSIGNED-PAYLOAD as the body hash.
    #
    # HTTP client options:
    # @option options [Integer] :max_connections (25)
    # @option options [Integer] :max_connection_idle_ms (60_000)
    # @option options [Integer] :connect_timeout_ms (60_000)
    # @option options [Integer] :read_timeout_ms (0) 0 means no timeout
    # @option options [Boolean] :ssl_verify_peer (true)
    # @option options [String] :ssl_ca_bundle (nil) path to CA bundle
    # @option options [Hash] :proxy (nil) proxy config with :host, :port,
    #   :username, :password
    def initialize(**options)
      raise ArgumentError, "missing required option :service" unless options[:service]

      _native_initialize(options)
    end

    # Sign and send an HTTP request in a single native call.
    #
    # The request is signed with SigV4 using the provided credentials,
    # then sent immediately over the connection pool. The CRT HTTP message
    # is built once and reused for both operations.
    #
    # @param endpoint [String] Full endpoint URL (e.g. "https://host:443")
    # @param method [String] HTTP method (GET, POST, etc.)
    # @param path [String] Request path with optional query string
    # @param headers [Array<Array(String, String)>] Request headers as
    #   [name, value] pairs. Must include a "host" header.
    # @param body [String, nil] Request body
    # @param credentials [Hash] Signing credentials and options:
    # @option credentials [String] :region (required) AWS region
    # @option credentials [String] :access_key_id (required)
    # @option credentials [String] :secret_access_key (required)
    # @option credentials [String] :session_token (nil)
    # @option credentials [Boolean] :streaming_io (false) Return body as
    #   SharableStringIO instead of String
    # @option credentials [Array<#call>] :on_data (nil) Listeners called
    #   with each body chunk
    # @option credentials [Array<#call>] :on_headers (nil) Listeners called
    #   with (status, headers_hash) when headers arrive
    # @option credentials [Array<String>] :checksum_algorithms (nil)
    #   Algorithms to compute over the response body
    # @option credentials [String, Pathname, File, Proc, Hash] :response_target (nil)
    #   Where to write the response body on 2xx success. Accepts a file path
    #   (String/Pathname), File object, Proc (called with body and headers),
    #   or Hash with :path and :offset keys for offset writes.
    #
    # @yield [chunk] For streaming responses, yields each body chunk
    # @yieldparam chunk [String] A chunk of the response body
    #
    # @return [AwsCrt::Http::Response] The HTTP response
    #
    # @raise [ArgumentError] if required options are missing
    # @raise [AwsCrt::Http::Error] on HTTP errors
    def request(endpoint, method, path, headers, body = nil, **options, &block) # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
      validate_credentials!(options)
      validate_headers!(headers)

      kwargs = {
        region: options[:region],
        access_key_id: options[:access_key_id],
        secret_access_key: options[:secret_access_key]
      }
      kwargs[:session_token] = options[:session_token] if options[:session_token]
      kwargs[:streaming_io] = options[:streaming_io] if options.key?(:streaming_io)
      kwargs[:on_data] = options[:on_data] if options.key?(:on_data)
      kwargs[:on_headers] = options[:on_headers] if options.key?(:on_headers)
      kwargs[:checksum_algorithms] = options[:checksum_algorithms] if options.key?(:checksum_algorithms)
      kwargs[:response_target] = options[:response_target] if options.key?(:response_target)

      if block
        _native_request(endpoint, method, path, headers, body, **kwargs, &block)
      else
        _native_request(endpoint, method, path, headers, body, **kwargs)
      end
    end

    private

    def validate_credentials!(credentials)
      %i[region access_key_id secret_access_key].each do |key|
        raise ArgumentError, "missing required credential :#{key}" unless credentials[key]
      end
    end

    def validate_headers!(headers)
      return if headers.is_a?(Array)

      raise ArgumentError, "headers must be an Array of [name, value] pairs"
    end
  end
end
