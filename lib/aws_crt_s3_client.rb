# frozen_string_literal: true

require_relative "aws_crt_s3_client/version"
require_relative "aws_crt_s3_client/aws_crt_s3_client"

module AwsCrtS3Client
  class Error < StandardError; end
end
