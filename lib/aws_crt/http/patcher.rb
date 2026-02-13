# frozen_string_literal: true

require_relative "plugin"

module AwsCrt
  module Http
    # Auto-patch mechanism that replaces the default HTTP handler on
    # AWS service clients with the CRT-backed handler.
    #
    # {patch!} does two things:
    # 1. Patches every AWS service client class that is already loaded.
    # 2. Installs a +TracePoint+ hook so that service client classes
    #    loaded *after* the patch are also covered.
    #
    # @example Activate via require (recommended)
    #   require "aws_crt/http"   # calls Patcher.patch! automatically
    #
    # @see Plugin
    module Patcher
      # Patch all currently-loaded and future AWS service clients.
      def self.patch!
        patch_existing_clients
        hook_future_clients
      end

      # Iterate constants under +Aws+ and add {Plugin} to every
      # service client class that inherits from +Seahorse::Client::Base+.
      def self.patch_existing_clients
        return unless defined?(::Aws)

        ::Aws.constants.each do |const_name|
          mod = ::Aws.const_get(const_name)
          next unless mod.is_a?(Module)
          next unless mod.const_defined?(:Client, false)

          client_class = mod.const_get(:Client)
          next unless client_class < ::Seahorse::Client::Base

          client_class.add_plugin(AwsCrt::Http::Plugin)
        end
      end

      # Install a +TracePoint+ hook that fires whenever a class body
      # finishes evaluation. If the class matches the AWS service
      # client naming pattern and inherits from +Seahorse::Client::Base+,
      # the plugin is added automatically.
      def self.hook_future_clients
        TracePoint.new(:class) do |tp|
          klass = tp.self
          if klass.name&.match?(/\AAws::\w+::Client\z/) &&
             klass < ::Seahorse::Client::Base
            klass.add_plugin(AwsCrt::Http::Plugin)
          end
        end.enable
      end
    end
  end
end
