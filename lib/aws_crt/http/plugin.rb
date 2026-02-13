# frozen_string_literal: true

require_relative "handler"

module AwsCrt
  module Http
    # Seahorse plugin that registers the CRT HTTP handler and its
    # configuration options on an AWS service client.
    #
    # Configuration options mirror the standard SDK HTTP options so
    # the CRT handler is a transparent replacement for Net::HTTP.
    #
    # @example Manual registration
    #   Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
    #   client = Aws::S3::Client.new(region: "us-east-1")
    class Plugin < Seahorse::Client::Plugin
      option(:http_open_timeout, default: 60)
      option(:http_read_timeout, default: 60)
      option(:ssl_verify_peer, default: true)
      option(:ssl_ca_bundle, default: nil)
      option(:http_proxy, default: nil)
      option(:max_connections, default: 25)
      option(:max_connection_idle_ms, default: 60_000)
      option(:logger, default: nil)

      option(:crt_pool_manager) do |config|
        AwsCrt::Http::ConnectionPoolManager.new(
          max_connections: config.max_connections,
          max_connection_idle_ms: config.max_connection_idle_ms,
          connect_timeout_ms: (config.http_open_timeout * 1000).to_i,
          read_timeout_ms: (config.http_read_timeout * 1000).to_i,
          ssl_verify_peer: config.ssl_verify_peer,
          ssl_ca_bundle: config.ssl_ca_bundle,
          proxy: config.http_proxy
        )
      end

      handler(Handler, step: :send)
    end
  end
end
