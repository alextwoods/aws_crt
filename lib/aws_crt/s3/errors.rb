# frozen_string_literal: true

require "aws_crt"

module AwsCrt
  module S3
    # Base error for all S3 operations.
    class Error < AwsCrt::Error; end

    # Raised when S3 returns an HTTP error response (4xx, 5xx).
    class ServiceError < Error
      # @return [Integer] HTTP status code
      attr_reader :status_code

      # @return [Hash<String, String>] response headers
      attr_reader :headers

      # @return [String] error response body (XML)
      attr_reader :error_body

      def initialize(message, status_code:, headers:, error_body:)
        super(message)
        @status_code = status_code
        @headers = headers
        @error_body = error_body
      end
    end

    # Raised for network/transport-level failures.
    class NetworkError < Error; end
  end
end
