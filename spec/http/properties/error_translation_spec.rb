# frozen_string_literal: true

# Feature: crt-http-client, Property 7: CRT Error Translation
#
# For any CRT error code that can be triggered during an HTTP operation,
# the resulting Ruby exception SHALL be an instance of
# AwsCrt::Http::Error (or a subclass), and its message SHALL contain
# the CRT error name string.
#
# **Validates: Requirements 10.1**
#
# Strategy: We trigger real CRT errors by attempting HTTP requests
# against endpoints that cannot succeed — ports with no listener and
# unreachable addresses. Each failure must raise an exception that:
#   1. Is an instance of AwsCrt::Http::Error (or a subclass)
#   2. Has a message containing a CRT error name (AWS_* prefix)
#
# We also verify the structural property that every defined error
# subclass inherits from AwsCrt::Http::Error and AwsCrt::Error.

require "socket"
require "rantly"
require "rantly/rspec_extensions"
require "aws_crt"

RSpec.describe "Property 7: CRT Error Translation" do
  # All error subclasses defined in the hierarchy.
  ERROR_SUBCLASSES = [
    AwsCrt::Http::ConnectionError,
    AwsCrt::Http::TimeoutError,
    AwsCrt::Http::TlsError,
    AwsCrt::Http::ProxyError
  ].freeze

  # CRT error names follow the AWS_* naming convention.
  CRT_ERROR_NAME_PATTERN = /AWS_\w+/

  # Find a TCP port on 127.0.0.1 that has no listener.
  # Binds a server socket, grabs the port, then closes it immediately.
  # There is a small race window, but for testing purposes this is
  # reliable enough — we *want* connection to fail.
  def find_unused_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  it "every error subclass inherits from AwsCrt::Http::Error and AwsCrt::Error" do
    property_of {
      choose(*ERROR_SUBCLASSES)
    }.check(20) do |klass|
      expect(klass).to be < AwsCrt::Http::Error,
        "#{klass} should be a subclass of AwsCrt::Http::Error"

      expect(klass).to be < AwsCrt::Error,
        "#{klass} should be a subclass of AwsCrt::Error"

      expect(klass).to be < StandardError,
        "#{klass} should be a subclass of StandardError"
    end
  end

  it "connection to a non-listening port raises AwsCrt::Http::Error with CRT error name" do
    property_of {
      range(1, 100) # dummy value to drive iterations
    }.check(10) do |_|
      port = find_unused_port

      pool = AwsCrt::Http::ConnectionPool.new(
        "http://127.0.0.1:#{port}",
        { connect_timeout_ms: 2_000 }
      )

      error = nil
      begin
        pool.request("GET", "/", [["Host", "127.0.0.1:#{port}"]])
      rescue AwsCrt::Http::Error => e
        error = e
      rescue StandardError => e
        # If it's not an Http::Error, that's a test failure
        raise "Expected AwsCrt::Http::Error (or subclass), got #{e.class}: #{e.message}"
      end

      expect(error).not_to be_nil,
        "Expected an AwsCrt::Http::Error to be raised for connection to " \
        "non-listening port #{port}, but no exception was raised"

      expect(error).to be_a(AwsCrt::Http::Error),
        "Exception #{error.class} should be an instance of AwsCrt::Http::Error"

      expect(error.message).to match(CRT_ERROR_NAME_PATTERN),
        "Error message should contain a CRT error name (AWS_*), " \
        "got: #{error.message.inspect}"
    end
  end

  it "connection errors are classified as ConnectionError" do
    property_of {
      range(1, 100) # dummy value to drive iterations
    }.check(10) do |_|
      port = find_unused_port

      pool = AwsCrt::Http::ConnectionPool.new(
        "http://127.0.0.1:#{port}",
        { connect_timeout_ms: 2_000 }
      )

      error = nil
      begin
        pool.request("GET", "/", [["Host", "127.0.0.1:#{port}"]])
      rescue AwsCrt::Http::Error => e
        error = e
      end

      expect(error).not_to be_nil,
        "Expected an error for connection to non-listening port #{port}"

      # Connection refused on a local port should be classified as
      # ConnectionError (AWS_IO_SOCKET_* errors).
      expect(error).to be_a(AwsCrt::Http::ConnectionError),
        "Expected AwsCrt::Http::ConnectionError for refused connection, " \
        "got #{error.class}: #{error.message}"

      # The message must contain the CRT error name
      expect(error.message).to match(CRT_ERROR_NAME_PATTERN),
        "Error message should contain CRT error name, got: #{error.message.inspect}"
    end
  end
end
