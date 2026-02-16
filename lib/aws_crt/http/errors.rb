# frozen_string_literal: true

# Error classes for the CRT HTTP client.
#
# The error hierarchy is defined in the Rust native extension
# (ext/aws_crt/src/error.rs) and registered during extension init.
# This file documents the hierarchy and ensures the classes are
# accessible via `require 'aws_crt/http/errors'`.
#
# Hierarchy:
#   AwsCrt::Error (defined in lib/aws_crt.rb)
#     └─ AwsCrt::Http::Error
#          ├─ AwsCrt::Http::ConnectionError  (DNS failures, connection refused)
#          ├─ AwsCrt::Http::TimeoutError     (connect/read timeouts)
#          ├─ AwsCrt::Http::TlsError         (handshake/cert failures)
#          └─ AwsCrt::Http::ProxyError       (proxy connection/auth failures)
#
# Each exception message includes the CRT error name, human-readable
# message, and numeric error code for debugging.

require "aws_crt"
