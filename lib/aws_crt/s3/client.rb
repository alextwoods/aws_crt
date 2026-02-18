# frozen_string_literal: true

require "aws_crt"
require "fileutils"
require "tempfile"
require_relative "credentials"
require_relative "errors"
require_relative "response"

module AwsCrt
  module S3
    # High-performance S3 client backed by the CRT's aws-c-s3 library.
    #
    # Wraps the Rust native `AwsCrt::S3::Client` class, adding Ruby-level
    # parameter validation, credential resolution, response object
    # construction, and error translation.
    #
    # Credentials are resolved fresh on every request by calling
    # `credentials` on the stored credential provider. This ensures that
    # temporary credentials (e.g. from STS AssumeRole) are refreshed
    # before they expire.
    #
    # @example With a credential provider (recommended)
    #   provider = Aws::SharedCredentials.new
    #   client = AwsCrt::S3::Client.new(
    #     region: 'us-east-1',
    #     credentials: provider
    #   )
    #
    # @example With a credentials object
    #   creds = AwsCrt::S3::Credentials.new(
    #     access_key_id: 'AKIA...',
    #     secret_access_key: 'secret'
    #   )
    #   client = AwsCrt::S3::Client.new(
    #     region: 'us-east-1',
    #     credentials: creds
    #   )
    #
    # @example With raw credential strings (backward compatible)
    #   client = AwsCrt::S3::Client.new(
    #     region: 'us-east-1',
    #     access_key_id: 'AKIA...',
    #     secret_access_key: 'secret'
    #   )
    #
    class Client # rubocop:disable Metrics/ClassLength
      # Alias the Rust-defined methods so we can wrap them with Ruby logic.
      alias _native_initialize initialize
      alias _native_get_object get_object
      alias _native_put_object put_object

      VALID_CHECKSUM_ALGORITHMS = %w[CRC32 CRC32C SHA1 SHA256].freeze

      # Chunk size for streaming tempfile data to block targets.
      STREAM_CHUNK_SIZE = 1024 * 1024 # 1 MB

      # IO bodies (for PUT) larger than this threshold are spilled to a
      # tempfile so the CRT can use send_filepath (parallel file I/O)
      # instead of buffering the entire body in memory. Configurable
      # via the :io_tempfile_threshold option on the client constructor.
      DEFAULT_IO_TEMPFILE_THRESHOLD = 16 * 1024 * 1024 # 16 MB

      # @param [Hash] options
      # @option options [String] :region (required) AWS region
      # @option options [#credentials, #access_key_id] :credentials
      #   A credential provider (responds to `credentials` returning an object
      #   with `access_key_id`, `secret_access_key`, `session_token`) or a
      #   credentials object (responds to `access_key_id`, `secret_access_key`,
      #   `session_token` directly).
      # @option options [String] :access_key_id (deprecated — use :credentials)
      # @option options [String] :secret_access_key (deprecated — use :credentials)
      # @option options [String] :session_token (deprecated — use :credentials)
      # @option options [Float] :throughput_target_gbps (10.0)
      # @option options [Integer] :part_size (nil) auto-tuned by CRT
      # @option options [Integer] :multipart_upload_threshold (nil)
      # @option options [Integer] :memory_limit_in_bytes (nil)
      # @option options [Integer] :max_active_connections_override (nil)
      # @option options [Integer] :io_tempfile_threshold (16 MB)
      #   IO bodies larger than this are spilled to a tempfile for
      #   CRT parallel file I/O instead of buffering in memory.
      def initialize(options = {}) # rubocop:disable Metrics/MethodLength
        validate_required_option!(options, :region)
        @credential_provider = resolve_credential_provider(options)
        @io_tempfile_threshold = options.fetch(:io_tempfile_threshold, DEFAULT_IO_TEMPFILE_THRESHOLD)

        # Resolve initial credentials for CRT client creation.
        initial_creds = @credential_provider.credentials
        native_options = options.slice(
          :region,
          :throughput_target_gbps,
          :part_size,
          :multipart_upload_threshold,
          :memory_limit_in_bytes,
          :max_active_connections_override
        ).merge(
          access_key_id: initial_creds.access_key_id,
          secret_access_key: initial_creds.secret_access_key,
          session_token: initial_creds.session_token
        )

        _native_initialize(native_options)
      end

      # Download an S3 object.
      #
      # @param [Hash] params
      # @option params [String] :bucket (required)
      # @option params [String] :key (required)
      # @option params [String, File, IO] :response_target (nil) file path, File, or IO object
      # @option params [String] :checksum_mode (nil) 'ENABLED' to validate
      # @option params [Proc] :on_progress (nil)
      # @yield [chunk] Each body chunk as it arrives
      # @return [AwsCrt::S3::Response]
      def get_object(params = {}, &block) # rubocop:disable Metrics/MethodLength
        stream_target, params = resolve_response_target(params, &block)

        begin
          result = _native_get_object(inject_credentials(params), &block)
          raise_if_error!(result)

          body = result[:body]

          if stream_target.is_a?(Proc)
            stream_tempfile_to_block(params[:response_target], stream_target)
            body = nil
          elsif stream_target
            stream_tempfile_to_io(params[:response_target], stream_target)
            body = nil
          end

          build_response(result, body)
        ensure
          # Clean up the tempfile if we created one for an IO/block target.
          FileUtils.rm_f(params[:response_target]) if stream_target
        end
      end

      # Upload an S3 object.
      #
      # @param [Hash] params
      # @option params [String] :bucket (required)
      # @option params [String] :key (required)
      # @option params [String, File, IO] :body (required)
      # @option params [Integer] :content_length (nil)
      # @option params [String] :content_type (nil)
      # @option params [String] :checksum_algorithm (nil) CRC32, CRC32C, SHA1, SHA256
      # @option params [Proc] :on_progress (nil)
      # @return [AwsCrt::S3::Response]
      def put_object(params = {})
        validate_checksum_algorithm!(params[:checksum_algorithm]) if params[:checksum_algorithm]

        params, tempfile_path = resolve_put_body(params)

        begin
          result = _native_put_object(inject_credentials(params))
          raise_if_error!(result)

          build_response(result, result[:body])
        ensure
          cleanup_put_tempfile(params, tempfile_path)
        end
      end

      private

      # Resolve a credential provider from the options hash.
      #
      # Accepts three forms:
      # 1. A credential provider (responds to `credentials` returning a
      #    credentials object) — used as-is.
      # 2. A credentials object (responds to `access_key_id` but not
      #    `credentials`) — wrapped in a StaticCredentialProvider.
      # 3. Raw strings `:access_key_id`, `:secret_access_key`,
      #    `:session_token` — wrapped in Credentials + StaticCredentialProvider.
      def resolve_credential_provider(options)
        creds_option = options[:credentials]

        if creds_option
          resolve_from_credentials_option(creds_option)
        elsif options.key?(:access_key_id) || options.key?(:secret_access_key)
          resolve_from_legacy_options(options)
        else
          raise ArgumentError,
                "missing credentials: provide :credentials (provider or " \
                "credentials object) or :access_key_id and :secret_access_key"
        end
      end

      def resolve_from_credentials_option(creds_option)
        if creds_option.respond_to?(:credentials)
          creds_option
        elsif creds_option.respond_to?(:access_key_id)
          StaticCredentialProvider.new(creds_option)
        else
          raise ArgumentError,
                ":credentials must respond to `credentials` (provider) " \
                "or `access_key_id` (credentials object)"
        end
      end

      def resolve_from_legacy_options(options)
        validate_credential_string!(options[:access_key_id], :access_key_id)
        validate_credential_string!(options[:secret_access_key], :secret_access_key)
        creds = Credentials.new(
          access_key_id: options[:access_key_id],
          secret_access_key: options[:secret_access_key],
          session_token: options[:session_token]
        )
        StaticCredentialProvider.new(creds)
      end

      # Resolve fresh credentials and inject them into the params hash
      # for the Rust native method.
      def inject_credentials(params)
        creds = @credential_provider.credentials
        params.merge(
          _access_key_id: creds.access_key_id,
          _secret_access_key: creds.secret_access_key,
          _session_token: creds.session_token
        )
      end

      # Resolve response_target (and block) into a form the CRT can use
      # efficiently. In every non-String case we route through a tempfile
      # so the CRT writes directly to disk via recv_filepath, then we
      # stream from the tempfile to the final destination in bounded
      # chunks.
      #
      # - String path: pass through unchanged (CRT writes directly).
      # - File object: extract its path for CRT direct file I/O.
      # - Generic IO object: tempfile → stream to IO in chunks.
      # - Block (no response_target): tempfile → yield chunks to block.
      # - No target, no block: pass through (body buffered in memory).
      #
      # Returns [stream_target, params] where stream_target is:
      # - the original IO object (for IO targets),
      # - the block as a Proc (for block streaming), or
      # - nil (for String path, buffered, or File targets).
      def resolve_response_target(params, &block)
        target = params[:response_target]

        if target
          return [nil, params] if target.is_a?(String)
          return [nil, params.merge(response_target: target.path)] if target.is_a?(File)

          # Generic IO — use a tempfile for CRT direct file I/O.
          [target, create_tempfile_params(params)]
        elsif block
          # Block streaming — use a tempfile so we don't buffer in memory.
          [block, create_tempfile_params(params)]
        else
          [nil, params]
        end
      end

      # Resolve the PUT body into a form the CRT can use efficiently.
      #
      # - String: pass through (Rust handles it directly).
      # - File: pass through (Rust extracts path for send_filepath).
      # - IO with known size >= threshold: spill to tempfile via
      #   IO.copy_stream, then pass the tempfile as a File so Rust
      #   uses send_filepath (parallel file I/O).
      # - IO with unknown or small size: pass through (Rust reads
      #   it into memory).
      #
      # Returns [params, tempfile_path] where tempfile_path is non-nil
      # only when we created a tempfile that needs cleanup.
      def resolve_put_body(params)
        body = params[:body]
        return [params, nil] unless body
        return [params, nil] if body.is_a?(String) || body.is_a?(File)
        return [params, nil] unless body.respond_to?(:size) && body.size >= @io_tempfile_threshold

        tempfile = Tempfile.new("aws-crt-s3-upload", binmode: true)
        IO.copy_stream(body, tempfile)
        tempfile.close
        # Re-open as a plain File so Rust sees respond_to?(:path) and
        # uses send_filepath. The put_object ensure block closes this
        # handle and deletes the tempfile.
        file = File.open(tempfile.path, "rb")
        [params.merge(body: file), tempfile.path]
      end

      # Create a tempfile and return params with its path as response_target.
      def create_tempfile_params(params)
        tempfile = Tempfile.new("aws-crt-s3-download")
        tempfile.close
        params.merge(response_target: tempfile.path)
      end

      # Clean up the tempfile and File handle created by resolve_put_body.
      def cleanup_put_tempfile(params, tempfile_path)
        return unless tempfile_path

        # Close the File handle opened by resolve_put_body before
        # deleting the underlying tempfile.
        body = params[:body]
        body.close if body.is_a?(File) && !body.closed?
        FileUtils.rm_f(tempfile_path)
      end

      # Stream data from a tempfile to an IO target using IO.copy_stream
      # for efficient kernel-level copying when available.
      def stream_tempfile_to_io(tempfile_path, io_target)
        ::File.open(tempfile_path, "rb") do |f|
          IO.copy_stream(f, io_target)
        end
      end

      # Stream data from a tempfile to a block in chunks.
      def stream_tempfile_to_block(tempfile_path, block)
        ::File.open(tempfile_path, "rb") do |f|
          while (chunk = f.read(STREAM_CHUNK_SIZE))
            block.call(chunk)
          end
        end
      end

      # Build a Response from a successful Rust result hash.
      def build_response(result, body)
        Response.new(
          status_code: result[:status_code],
          headers: result[:headers],
          body: body,
          checksum_validated: result[:checksum_validated]
        )
      end

      # Validate that a required option is present and non-nil.
      def validate_required_option!(options, key)
        value = options[key]
        return unless value.nil? || (value.is_a?(String) && value.empty?)

        raise ArgumentError, "missing required option :#{key}"
      end

      # Validate that a credential string is present and non-empty.
      def validate_credential_string!(value, key)
        return unless value.nil? || (value.is_a?(String) && value.empty?)

        raise ArgumentError, "missing required option :#{key}"
      end

      # Validate that a checksum algorithm is one of the supported values.
      def validate_checksum_algorithm!(algorithm)
        return if VALID_CHECKSUM_ALGORITHMS.include?(algorithm)

        raise ArgumentError,
              "invalid checksum_algorithm '#{algorithm}': " \
              "must be CRC32, CRC32C, SHA1, or SHA256"
      end

      # Inspect a result hash from the Rust layer and raise the appropriate
      # error if it represents a failure.
      def raise_if_error!(result) # rubocop:disable Metrics/MethodLength
        return unless result[:error]

        error_code = result[:error_code]
        status_code = result[:status_code]
        headers = result[:headers] || {}
        body = result[:body] || ""

        unless error_code.zero? && status_code >= 400
          raise NetworkError, "S3 network error (CRT error code: #{error_code}): #{body}"
        end

        raise ServiceError.new(
          "S3 service error: HTTP #{status_code}",
          status_code: status_code,
          headers: headers,
          error_body: body
        )
      end
    end
  end
end
