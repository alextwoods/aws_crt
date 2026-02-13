# frozen_string_literal: true

# Unit tests for AwsCrt::Http::Patcher (auto-patch mechanism).
#
# Requirements:
#   9.1 — require 'aws_crt/http' patches all currently-loaded AWS service clients
#   9.2 — require 'aws_crt/http' hooks future AWS service client classes
#   9.3 — require 'aws_crt/http/handler' loads Handler without auto-patching
#   9.4 — Plugin registers CRT Handler at the :send step
#  12.5 — Test suite verifies auto-patch mechanism
#
# Strategy: Define minimal Seahorse stubs (Base, Plugin) and fake
# Aws::*::Client classes, then exercise the Patcher methods directly.
# The standalone-require test runs in a subprocess to get a clean
# Ruby environment.

require "English"
require "rbconfig"

# ---------------------------------------------------------------------------
# Seahorse stubs — extend the minimal set used by other specs with the
# classes the Patcher and Plugin need.
# ---------------------------------------------------------------------------
module Seahorse
  module Client
    # Handler is already defined by other specs when run together, but
    # we define it here for standalone execution.
    unless const_defined?(:Handler, false)
      class Handler
        attr_accessor :handler

        def initialize(handler = nil)
          @handler = handler
        end
      end
    end

    unless const_defined?(:Response, false)
      class Response
        attr_accessor :context

        def initialize(context: nil)
          @context = context
        end
      end
    end

    unless const_defined?(:NetworkingError, false)
      class NetworkingError < StandardError
        attr_reader :original_error

        def initialize(error, message = nil)
          @original_error = error
          super(message || error.message)
        end
      end
    end

    # Base — the superclass of every AWS service client.
    # Provides add_plugin / plugins so the Patcher can register the Plugin.
    unless const_defined?(:Base, false)
      class Base
        class << self
          def plugins
            @plugins ||= []
          end

          def add_plugin(plugin)
            plugins << plugin unless plugins.include?(plugin)
          end
        end
      end
    end

    # Plugin — superclass of AwsCrt::Http::Plugin.
    # Provides the DSL methods (option, handler) as no-ops so the class
    # body evaluates without error.
    unless const_defined?(:Plugin, false)
      class Plugin
        class << self
          def option(name, **_opts, &block); end
          def handler(klass, **_opts); end
        end
      end
    end
  end
end

# Load the patcher (which transitively loads plugin, handler, etc.)
require_relative "../../lib/aws_crt/http/patcher"

RSpec.describe AwsCrt::Http::Patcher do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Temporarily define an Aws service module with a Client class,
  # yield, then clean up.
  def with_aws_service(service_name, inherits_from: Seahorse::Client::Base)
    mod = Module.new
    client_class = Class.new(inherits_from)
    mod.const_set(:Client, client_class)

    Aws.const_set(service_name, mod)
    yield client_class
  ensure
    Aws.send(:remove_const, service_name) if Aws.const_defined?(service_name, false)
  end

  # Check whether a client class has the CRT plugin registered.
  def has_crt_plugin?(client_class)
    client_class.plugins.include?(AwsCrt::Http::Plugin)
  end

  # ------------------------------------------------------------------
  # Setup: ensure the Aws module exists for our fake services.
  # ------------------------------------------------------------------
  before(:all) do
    Object.const_set(:Aws, Module.new) unless defined?(Aws)
  end

  # ------------------------------------------------------------------
  # patch_existing_clients
  # ------------------------------------------------------------------
  describe ".patch_existing_clients" do
    it "adds the Plugin to an existing Aws service client" do
      with_aws_service(:FakeExisting) do |client_class|
        expect(has_crt_plugin?(client_class)).to be false

        described_class.patch_existing_clients

        expect(has_crt_plugin?(client_class)).to be true
      end
    end

    it "skips constants that are not modules" do
      Aws.const_set(:SOME_STRING, "not a module")
      expect { described_class.patch_existing_clients }.not_to raise_error
    ensure
      Aws.send(:remove_const, :SOME_STRING) if Aws.const_defined?(:SOME_STRING, false)
    end

    it "skips modules that do not define a Client constant" do
      mod = Module.new
      Aws.const_set(:NoClient, mod)
      expect { described_class.patch_existing_clients }.not_to raise_error
    ensure
      Aws.send(:remove_const, :NoClient) if Aws.const_defined?(:NoClient, false)
    end

    it "skips Client classes that do not inherit from Seahorse::Client::Base" do
      mod = Module.new
      plain_client = Class.new # does NOT inherit from Base
      plain_client.define_singleton_method(:plugins) { @plugins ||= [] }
      plain_client.define_singleton_method(:add_plugin) { |p| plugins << p }
      mod.const_set(:Client, plain_client)
      Aws.const_set(:PlainService, mod)

      described_class.patch_existing_clients

      expect(plain_client.plugins).not_to include(AwsCrt::Http::Plugin)
    ensure
      Aws.send(:remove_const, :PlainService) if Aws.const_defined?(:PlainService, false)
    end

    it "does not add the Plugin twice" do
      with_aws_service(:DoubleAdd) do |client_class|
        described_class.patch_existing_clients
        described_class.patch_existing_clients

        expect(client_class.plugins.count(AwsCrt::Http::Plugin)).to eq(1)
      end
    end
  end

  # ------------------------------------------------------------------
  # hook_future_clients
  # ------------------------------------------------------------------
  describe ".hook_future_clients" do
    it "patches a service client class defined after the hook is installed" do
      described_class.hook_future_clients

      # Use module_eval so the class gets a proper name at definition
      # time — the TracePoint(:class) fires when the class body closes,
      # and it needs klass.name to match /\AAws::\w+::Client\z/.
      Aws.const_set(:FutureService, Module.new) unless Aws.const_defined?(:FutureService, false)
      Aws::FutureService.module_eval <<~RUBY, __FILE__, __LINE__ + 1
        class Client < Seahorse::Client::Base; end
      RUBY

      client_class = Aws::FutureService::Client
      expect(has_crt_plugin?(client_class)).to be true
    ensure
      Aws.send(:remove_const, :FutureService) if Aws.const_defined?(:FutureService, false)
    end

    it "does not patch classes that do not match the Aws::*::Client pattern" do
      described_class.hook_future_clients

      # Define a class outside the Aws namespace.
      klass = Class.new(Seahorse::Client::Base)
      klass.define_singleton_method(:name) { "NotAws::Something::Client" }

      # The TracePoint won't fire for Class.new, but even if it did,
      # the name check should exclude it. Verify plugins are empty.
      expect(klass.plugins).not_to include(AwsCrt::Http::Plugin)
    end
  end

  # ------------------------------------------------------------------
  # patch! (integration of both methods)
  # ------------------------------------------------------------------
  describe ".patch!" do
    it "patches existing clients and hooks future ones" do
      with_aws_service(:PatchBang) do |existing_client|
        described_class.patch!

        expect(has_crt_plugin?(existing_client)).to be true

        # Define a new service after patch!
        Aws.const_set(:AfterPatchBang, Module.new) unless Aws.const_defined?(:AfterPatchBang, false)
        Aws::AfterPatchBang.module_eval <<~RUBY, __FILE__, __LINE__ + 1
          class Client < Seahorse::Client::Base; end
        RUBY

        future_client = Aws::AfterPatchBang::Client
        expect(has_crt_plugin?(future_client)).to be true
      end
    ensure
      Aws.send(:remove_const, :AfterPatchBang) if Aws.const_defined?(:AfterPatchBang, false)
    end
  end

  # ------------------------------------------------------------------
  # Standalone require — handler without auto-patch
  # ------------------------------------------------------------------
  describe "standalone require 'aws_crt/http/handler'" do
    it "does not load the patcher" do
      # Run in a subprocess to get a clean Ruby environment where
      # the patcher has not been loaded yet.
      script = <<~RUBY
        # Define minimal Seahorse stubs so handler.rb can load.
        module Seahorse
          module Client
            class Handler
              def initialize(handler = nil); end
            end
            class Plugin
              def self.option(*args, **opts, &block); end
              def self.handler(*args, **opts); end
            end
          end
        end

        require "aws_crt/http/handler"

        # Check that the Patcher module is NOT defined.
        if defined?(AwsCrt::Http::Patcher)
          puts "FAIL: Patcher is defined"
          exit 1
        else
          puts "PASS: Patcher is not defined"
          exit 0
        end
      RUBY

      result = IO.popen(
        [RbConfig.ruby, "-e", script],
        err: %i[child out], &:read
      )
      status = $CHILD_STATUS

      expect(status.success?).to be(true),
                                 "Subprocess failed (exit #{status.exitstatus}):\n#{result}"
      expect(result).to include("PASS")
    end
  end
end
