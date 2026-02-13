# frozen_string_literal: true

require_relative "connection_pool"

module AwsCrt
  module Http
    # Thread-safe registry of ConnectionPool instances keyed by endpoint.
    #
    # Each unique endpoint (e.g. "https://s3.amazonaws.com:443") gets its
    # own ConnectionPool. Repeated calls to {#pool_for} with the same
    # endpoint return the same pool instance.
    #
    # @example
    #   manager = ConnectionPoolManager.new(max_connections: 10)
    #   pool = manager.pool_for("https://s3.amazonaws.com:443")
    #   pool.request("GET", "/", [["Host", "s3.amazonaws.com"]])
    class ConnectionPoolManager
      # @param options [Hash] Default options passed to each new ConnectionPool.
      #   See {ConnectionPool#initialize} for supported keys.
      def initialize(options = {})
        @pools = {}
        @mutex = Mutex.new
        @options = options
      end

      # Returns the ConnectionPool for the given endpoint, creating one
      # if it doesn't already exist.
      #
      # @param endpoint [String] e.g. "https://example.com:443"
      # @return [ConnectionPool]
      def pool_for(endpoint)
        @mutex.synchronize do
          @pools[endpoint] ||= ConnectionPool.new(endpoint, @options)
        end
      end
    end
  end
end
