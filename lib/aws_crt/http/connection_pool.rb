# frozen_string_literal: true

# Ruby wrapper for the CRT HTTP connection pool.
#
# The AwsCrt::Http::ConnectionPool class is defined in the Rust native
# extension (ext/aws_crt/src/pool.rs). This file ensures the native
# extension is loaded and documents the Ruby API.
#
# @example Create a pool and make a request
#   pool = AwsCrt::Http::ConnectionPool.new("https://example.com:443",
#     max_connections: 25,
#     connect_timeout_ms: 60_000,
#     read_timeout_ms: 60_000,
#     ssl_verify_peer: true
#   )
#
#   status, headers, body = pool.request("GET", "/", [["Host", "example.com"]])
#
# @example Streaming response
#   pool.request("GET", "/large", [["Host", "example.com"]]) do |chunk|
#     io.write(chunk)
#   end
#
# @see AwsCrt::Http::ConnectionPoolManager for per-endpoint pool management

require "aws_crt"
