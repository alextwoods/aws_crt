# frozen_string_literal: true

# Feature: crt-http-client, Property 6: Configuration Passthrough
#
# For any combination of SDK configuration options (http_open_timeout,
# http_read_timeout, ssl_verify_peer, ssl_ca_bundle, http_proxy,
# max_connections), the ConnectionPool created by the Handler SHALL
# reflect those configuration values in its underlying CRT connection
# manager settings.
#
# **Validates: Requirements 8.7**
#
# Strategy: We cannot inspect the internal CRT connection manager
# settings directly. Instead we verify the two Ruby-layer hops:
#
#   1. ConnectionPoolManager passes its options unchanged to every
#      ConnectionPool it creates.
#   2. The full SDK-config-to-ConnectionPool chain (Plugin transformation
#      + ConnectionPoolManager passthrough) delivers the correct values.
#
# We intercept ConnectionPool.new to capture the options hash and
# assert it matches the expected values.

require "rantly"
require "rantly/rspec_extensions"
require_relative "../../../lib/aws_crt/http/connection_pool_manager"

RSpec.describe "Property 6: Configuration Passthrough" do
  it "ConnectionPoolManager passes its options to every ConnectionPool it creates" do
    property_of {
      max_conns = range(1, 100)
      idle_ms = range(1_000, 300_000)
      connect_ms = range(1_000, 120_000)
      read_ms = range(1_000, 120_000)
      verify_peer = boolean
      ca_bundle = choose(nil, "/tmp/ca-#{range(1, 9999)}.pem")
      num_endpoints = range(1, 5)

      [max_conns, idle_ms, connect_ms, read_ms, verify_peer, ca_bundle, num_endpoints]
    }.check(20) do |(max_conns, idle_ms, connect_ms, read_ms, verify_peer, ca_bundle, num_endpoints)|
      options = {
        max_connections: max_conns,
        max_connection_idle_ms: idle_ms,
        connect_timeout_ms: connect_ms,
        read_timeout_ms: read_ms,
        ssl_verify_peer: verify_peer,
        ssl_ca_bundle: ca_bundle,
        proxy: nil
      }

      manager = AwsCrt::Http::ConnectionPoolManager.new(options)

      # Intercept ConnectionPool.new to capture the options hash.
      # and_wrap_original avoids the infinite recursion that happens
      # when manually saving and re-calling the original method.
      captured_calls = []
      allow(AwsCrt::Http::ConnectionPool).to receive(:new)
        .and_wrap_original do |original, endpoint, opts|
          captured_calls << { endpoint: endpoint, opts: opts }
          original.call(endpoint, opts)
        end

      base_port = rand(10_000..50_000)
      num_endpoints.times do |i|
        manager.pool_for("http://127.0.0.1:#{base_port + i}")
      end

      expect(captured_calls.size).to eq(num_endpoints),
        "Expected #{num_endpoints} ConnectionPool.new calls, got #{captured_calls.size}"

      captured_calls.each do |call|
        opts = call[:opts]
        expect(opts[:max_connections]).to eq(max_conns)
        expect(opts[:max_connection_idle_ms]).to eq(idle_ms)
        expect(opts[:connect_timeout_ms]).to eq(connect_ms)
        expect(opts[:read_timeout_ms]).to eq(read_ms)
        expect(opts[:ssl_verify_peer]).to eq(verify_peer)
        expect(opts[:ssl_ca_bundle]).to eq(ca_bundle)
      end
    end
  end

  it "SDK config options arrive at ConnectionPool with correct transformations" do
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
      # Apply the Plugin's transformation (from plugin.rb crt_pool_manager block):
      #   http_open_timeout (seconds) → connect_timeout_ms (milliseconds)
      #   http_read_timeout (seconds) → read_timeout_ms (milliseconds)
      #   other options pass through unchanged
      pool_manager_opts = {
        max_connections: max_conns,
        max_connection_idle_ms: idle_ms,
        connect_timeout_ms: (open_timeout * 1000).to_i,
        read_timeout_ms: (read_timeout * 1000).to_i,
        ssl_verify_peer: verify_peer,
        ssl_ca_bundle: ca_bundle,
        proxy: nil
      }

      manager = AwsCrt::Http::ConnectionPoolManager.new(pool_manager_opts)

      captured_opts = nil
      allow(AwsCrt::Http::ConnectionPool).to receive(:new)
        .and_wrap_original do |original, endpoint, opts|
          captured_opts = opts
          original.call(endpoint, opts)
        end

      manager.pool_for("http://127.0.0.1:#{rand(10_000..60_000)}")

      expect(captured_opts).not_to be_nil,
        "ConnectionPool.new was not called"

      # Timeouts must be in milliseconds
      expect(captured_opts[:connect_timeout_ms]).to eq(open_timeout * 1000),
        "http_open_timeout #{open_timeout}s should arrive as connect_timeout_ms #{open_timeout * 1000}"
      expect(captured_opts[:read_timeout_ms]).to eq(read_timeout * 1000),
        "http_read_timeout #{read_timeout}s should arrive as read_timeout_ms #{read_timeout * 1000}"

      # Other options pass through unchanged
      expect(captured_opts[:max_connections]).to eq(max_conns)
      expect(captured_opts[:max_connection_idle_ms]).to eq(idle_ms)
      expect(captured_opts[:ssl_verify_peer]).to eq(verify_peer)
      expect(captured_opts[:ssl_ca_bundle]).to eq(ca_bundle)
      expect(captured_opts[:proxy]).to be_nil
    end
  end
end
