# frozen_string_literal: true

module AwsCrt
  module S3
    # Structured response from S3 get_object and put_object operations.
    class Response
      # @return [Integer] HTTP status code
      attr_reader :status_code

      # @return [Hash<String, String>] response headers
      attr_reader :headers

      # @return [String, nil] response body (nil when streamed to a target)
      attr_reader :body

      # @return [String, nil] checksum algorithm used for validation
      attr_reader :checksum_validated

      # @param status_code [Integer] HTTP status code
      # @param headers [Hash<String, String>] response headers
      # @param body [String, nil] response body
      # @param checksum_validated [String, nil] checksum algorithm validated
      def initialize(status_code:, headers:, body: nil, checksum_validated: nil)
        @status_code = status_code
        @headers = headers
        @body = body
        @checksum_validated = checksum_validated
      end

      # @return [Boolean] true if the response status code is 2xx
      def successful?
        status_code >= 200 && status_code < 300
      end
    end
  end
end
