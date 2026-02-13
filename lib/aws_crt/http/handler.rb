# frozen_string_literal: true

require_relative "errors"
require_relative "connection_pool"
require_relative "connection_pool_manager"

module AwsCrt
  module Http
    # Seahorse handler that sends HTTP requests through the CRT client.
    #
    # Drop-in replacement for `Seahorse::Client::NetHttp::Handler`.
    # Register via {Plugin} or manually on a service client.
    class Handler < Seahorse::Client::Handler
      # @param context [Seahorse::Client::RequestContext]
      # @return [Seahorse::Client::Response]
      def call(context)
        pool = pool_for(context)
        resp = context.http_response
        start = monotonic_time
        send_request(pool, context.http_request, resp, streaming?(context))
        log_request(context, start)
      rescue AwsCrt::Http::Error => e
        context.http_response.signal_error(
          Seahorse::Client::NetworkingError.new(e, e.message)
        )
      ensure
        return Seahorse::Client::Response.new(context: context) # rubocop:disable Lint/EnsureReturn
      end

      private

      def send_request(pool, req, resp, streaming)
        method = req.http_method
        path = req.endpoint.request_uri
        headers = build_headers(req)
        body = read_body(req.body)

        if streaming
          stream_response(pool, method, path, headers, body, resp)
        else
          buffer_response(pool, method, path, headers, body, resp)
        end
      end

      def buffer_response(pool, method, path, headers, body, resp) # rubocop:disable Metrics/ParameterLists
        args = [method, path, headers]
        args << body unless body.nil?
        t = Time.now
        status, resp_headers, resp_body = pool.request(*args)
        resp.signal_headers(status, headers_to_hash(resp_headers))
        resp.signal_data(resp_body) unless resp_body.empty?
        resp.signal_done
      end

      def stream_response(pool, method, path, headers, body, resp) # rubocop:disable Metrics/ParameterLists
        args = [method, path, headers]
        args << body unless body.nil?
        status, resp_headers = pool.request(*args) do |chunk|
          resp.signal_data(chunk)
        end
        resp.signal_headers(status, headers_to_hash(resp_headers))
        resp.signal_done
      end

      def pool_for(context)
        pool_manager = context.config.crt_pool_manager
        endpoint = context.http_request.endpoint
        pool_manager.pool_for("#{endpoint.scheme}://#{endpoint.host}:#{endpoint.port}")
      end

      def build_headers(req)
        headers = []
        req.headers.each_pair { |name, value| headers << [name, value] }
        headers
      end

      def read_body(body)
        return nil if body.nil?

        data = body.respond_to?(:read) ? body.read : body.to_s
        body.rewind if body.respond_to?(:rewind)
        data.empty? ? nil : data
      end

      def headers_to_hash(headers)
        hash = {}
        headers.each { |name, value| hash[name] = value }
        hash
      end

      def streaming?(context)
        target = context[:response_target]
        target.is_a?(Proc) ||
          (target.respond_to?(:write) && target.respond_to?(:close))
      end

      def log_request(context, start_time)
        logger = context.config.respond_to?(:logger) && context.config.logger
        return unless logger

        elapsed = monotonic_time - start_time
        req = context.http_request
        logger.debug(
          format("[AwsCrt::Http] %s %s -> %s (%.4fs)",
                 req.http_method, req.endpoint,
                 context.http_response.status_code, elapsed)
        )
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
