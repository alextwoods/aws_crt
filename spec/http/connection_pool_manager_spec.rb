# frozen_string_literal: true

# Unit tests for AwsCrt::Http::ConnectionPoolManager.
#
# Requirements: 8.5 — THE Handler SHALL maintain a ConnectionPool per unique
#   endpoint, creating new pools as needed and reusing existing pools for
#   repeated calls to the same endpoint.

require_relative "../../lib/aws_crt/http/connection_pool_manager"

RSpec.describe AwsCrt::Http::ConnectionPoolManager do
  # Use HTTP endpoints on 127.0.0.1 with distinct ports to avoid TLS/DNS.
  let(:endpoint_a) { "http://127.0.0.1:19876" }
  let(:endpoint_b) { "http://127.0.0.1:19877" }

  describe "#initialize" do
    it "creates a manager with default options" do
      manager = described_class.new
      expect(manager).to be_a(described_class)
    end

    it "accepts configuration options" do
      manager = described_class.new(max_connections: 10, connect_timeout_ms: 5_000)
      expect(manager).to be_a(described_class)
    end
  end

  describe "#pool_for" do
    it "returns a ConnectionPool instance" do
      manager = described_class.new
      pool = manager.pool_for(endpoint_a)
      expect(pool).to be_a(AwsCrt::Http::ConnectionPool)
    end

    it "returns the same pool for the same endpoint" do
      manager = described_class.new
      pool1 = manager.pool_for(endpoint_a)
      pool2 = manager.pool_for(endpoint_a)
      expect(pool1).to equal(pool2)
    end

    it "returns different pools for different endpoints" do
      manager = described_class.new
      pool_a = manager.pool_for(endpoint_a)
      pool_b = manager.pool_for(endpoint_b)
      expect(pool_a).not_to equal(pool_b)
    end

    it "passes options to the created ConnectionPool" do
      # Verify that custom options don't cause errors during pool creation.
      manager = described_class.new(
        max_connections: 5,
        connect_timeout_ms: 10_000,
        max_connection_idle_ms: 30_000
      )
      pool = manager.pool_for(endpoint_a)
      expect(pool).to be_a(AwsCrt::Http::ConnectionPool)
    end

    it "is safe to call from multiple threads" do
      manager = described_class.new
      pools = Array.new(10)

      threads = 10.times.map do |i|
        Thread.new { pools[i] = manager.pool_for(endpoint_a) }
      end
      threads.each(&:join)

      # All threads should get the same pool instance
      pools.each do |pool|
        expect(pool).to equal(pools[0])
      end
    end
  end
end
