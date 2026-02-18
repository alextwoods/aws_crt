# frozen_string_literal: true

module AwsCrt
  module S3
    # Simple credentials object holding access key, secret key, and optional
    # session token. Matches the interface expected by the AWS SDK for Ruby.
    class Credentials
      # @return [String] AWS access key ID
      attr_reader :access_key_id

      # @return [String] AWS secret access key
      attr_reader :secret_access_key

      # @return [String, nil] AWS session token
      attr_reader :session_token

      # @param access_key_id [String]
      # @param secret_access_key [String]
      # @param session_token [String, nil]
      def initialize(access_key_id:, secret_access_key:, session_token: nil)
        @access_key_id = access_key_id
        @secret_access_key = secret_access_key
        @session_token = session_token
      end
    end

    # A credential provider that always returns the same static credentials.
    # Used internally when the user passes raw credential strings or a
    # credentials object directly (rather than a provider).
    class StaticCredentialProvider
      # @return [Credentials, #access_key_id] the static credentials
      attr_reader :credentials

      # @param credentials [Credentials, #access_key_id] a credentials object
      def initialize(credentials)
        @credentials = credentials
      end
    end
  end
end
