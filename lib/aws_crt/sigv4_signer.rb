# frozen_string_literal: true

module AwsCrt
  # CRT-backed SigV4 request signer.
  #
  # A standalone, high-performance request signer that uses the AWS Common
  # Runtime (CRT) to compute SigV4 signatures. The entire signing operation
  # (canonical request construction, string-to-sign computation, signature
  # calculation, and header injection) happens in native code with the Ruby
  # GVL released during the CRT's async signing callback.
  #
  # The signer is configured once with a service name and signing options,
  # then reused for multiple requests. Credentials and region are provided
  # per-call to support credential rotation and multi-region use.
  #
  # @example Basic usage
  #   signer = AwsCrt::Sigv4Signer.new(service: 'sts')
  #   signed = signer.sign_request(
  #     region: 'us-east-1',
  #     access_key_id: 'AKIA...',
  #     secret_access_key: 'secret',
  #     method: 'POST',
  #     uri: '/',
  #     headers: [['host', 'sts.amazonaws.com'], ['content-type', 'application/x-www-form-urlencoded']],
  #     body: 'Action=GetCallerIdentity&Version=2011-06-15'
  #   )
  #   signed[:headers]  # => [["host", "sts.amazonaws.com"], ["content-type", "..."], ["X-Amz-Date", "..."], ...]
  #
  # @example With a credential provider
  #   provider = Aws::SharedCredentials.new
  #   creds = provider.credentials
  #   signed = signer.sign_request(
  #     region: 'us-east-1',
  #     access_key_id: creds.access_key_id,
  #     secret_access_key: creds.secret_access_key,
  #     session_token: creds.session_token,
  #     method: 'GET',
  #     uri: '/',
  #     headers: [['host', 'sts.amazonaws.com']]
  #   )
  #
  # @example S3-style signing (no double URI encode, unsigned payload)
  #   signer = AwsCrt::Sigv4Signer.new(
  #     service: 's3',
  #     use_double_uri_encode: false,
  #     normalize_uri_path: false
  #   )
  #
  class Sigv4Signer
    # Alias the Rust-defined methods so we can wrap them with Ruby logic.
    alias _native_initialize initialize
    alias _native_sign_request sign_request

    # @param [Hash] options
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
    def initialize(**options)
      raise ArgumentError, "missing required option :service" unless options[:service]

      _native_initialize(options)
    end

    # Sign an HTTP request with SigV4.
    #
    # The signing operation adds Authorization, X-Amz-Date, and optionally
    # X-Amz-Security-Token and x-amz-content-sha256 headers. The original
    # headers are preserved; signing headers are appended.
    #
    # @param [Hash] request
    # @option request [String] :region (required) AWS region
    # @option request [String] :access_key_id (required) AWS access key ID
    # @option request [String] :secret_access_key (required) AWS secret access key
    # @option request [String] :session_token (nil) AWS session token
    # @option request [String] :method (required) HTTP method
    # @option request [String] :uri (required) Request URI path with query string
    # @option request [Array<Array(String, String)>] :headers (required)
    #   Request headers as [name, value] pairs. Must include a "host" header.
    # @option request [String] :body (nil) Request body
    #
    # @return [Hash] with keys:
    #   - :headers [Array<Array(String, String)>] — all headers including signing headers
    #   - :method [String] — HTTP method (unchanged)
    #   - :uri [String] — URI path (unchanged)
    #
    # @raise [ArgumentError] if required options are missing
    # @raise [AwsCrt::Error] if the CRT signing operation fails
    def sign_request(**request)
      validate_sign_request!(request)
      _native_sign_request(request)
    end

    private

    def validate_sign_request!(request)
      %i[region access_key_id secret_access_key method uri headers].each do |key|
        raise ArgumentError, "missing required option :#{key}" unless request.key?(key)
      end

      return if request[:headers].is_a?(Array)

      raise ArgumentError, ":headers must be an Array of [name, value] pairs"
    end
  end
end
