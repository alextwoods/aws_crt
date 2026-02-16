# frozen_string_literal: true

require_relative "aws_crt/version"

module AwsCrt
  class Error < StandardError; end
end

# Load the native extension after AwsCrt::Error is defined,
# since the Rust init code references it to build the Http error hierarchy.
require_relative "aws_crt/aws_crt"
