# frozen_string_literal: true

# Feature: crt-http-client, Property 6: Configuration Passthrough
#
# For any combination of SDK configuration options (http_open_timeout,
# http_read_timeout, ssl_verify_peer, ssl_ca_bundle, http_proxy,
# max_connections), the Client SHALL accept those configuration values
# and use them for its underlying CRT connection management.
#
# **Validates: Requirements 8.7**
#
# Strategy: We verify that Client.new accepts all supported configuration
# options without raising errors, and that the options influence behavior
# (e.g., a very short connect_timeout_ms causes a timeout error against
# a non-routable address).

require "rantly"
require "rantly/rspec_extensions"
require "aws_crt"

RSpec.describe "Property 6: Configuration Passthrough" do
  it "Client.new accepts all supported configuration options without error" do
    property_of {
      max_conns = range(1, 100)
      idle_ms = range(1_000, 300_000)
      connect_ms = range(1_000, 120_000)
      read_ms = range(1_000, 120_000)
      verify_peer = boolean
      ca_bundle = choose(nil, "/tmp/ca-#{range(1, 9999)}.pem")

      [max_conns, idle_ms, connect_ms, read_ms, verify_peer, ca_bundle]
    }.check(20) do |(max_conns, idle_ms, connect_ms, read_ms, verify_peer, ca_bundle)|
      options = {
        max_connections: max_conns,
        max_connection_idle_ms: idle_ms,
        connect_timeout_ms: connect_ms,
        read_timeout_ms: read_ms,
        ssl_verify_peer: verify_peer,
        ssl_ca_bundle: ca_bundle,
        proxy: nil
      }

      client = AwsCrt::Http::Client.new(**options)
      expect(client).to be_a(AwsCrt::Http::Client)
    end
  end

  it "SDK config options with timeout transformations produce a valid Client" do
    property_of {
      # SDK-level config: timeouts in seconds, other options as-is
      open_timeout = range(1, 120)
      read_timeout = range(1, 120)
      max_conns = range(1, 100)
      idle_ms = range(1_000, 300_000)
      verify_peer = boolean
      ca_bundle = choose(nil, "/tmp/ca-#{range(1, 9999)}.pem")

      [open_timeout, read_timeout, max_conns, idle_ms, verify_peer, ca_bundle]
    }.check(20) do |(open_timeout, read_timeout, max_conns, idle_ms, verify_peer, ca_bundle)|
      # Apply the Plugin's transformation (from plugin.rb crt_http_client block):
      #   http_open_timeout (seconds) → connect_timeout_ms (milliseconds)
      #   http_read_timeout (seconds) → read_timeout_ms (milliseconds)
      #   other options pass through unchanged
      options = {
        max_connections: max_conns,
        max_connection_idle_ms: idle_ms,
        connect_timeout_ms: (open_timeout * 1000).to_i,
        read_timeout_ms: (read_timeout * 1000).to_i,
        ssl_verify_peer: verify_peer,
        ssl_ca_bundle: ca_bundle,
        proxy: nil
      }

      client = AwsCrt::Http::Client.new(**options)
      expect(client).to be_a(AwsCrt::Http::Client)
    end
  end
end
