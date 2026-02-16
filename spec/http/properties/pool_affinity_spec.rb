# frozen_string_literal: true

# Feature: crt-http-client, Property 5: Connection Pool Endpoint Affinity
#
# For any sequence of requests to a set of endpoints, the
# ConnectionPoolManager SHALL return the same ConnectionPool instance for
# requests to the same endpoint, and distinct ConnectionPool instances for
# requests to different endpoints.
# Formally: pool_for(e1) == pool_for(e1) and
#           e1 != e2 → pool_for(e1) != pool_for(e2)
#
# **Validates: Requirements 8.5**

require "rantly"
require "rantly/rspec_extensions"
require_relative "../../../lib/aws_crt/http/connection_pool_manager"

RSpec.describe "Property 5: Connection Pool Endpoint Affinity" do
  # Generate distinct endpoint strings using unique ports on 127.0.0.1.
  # Using HTTP avoids TLS setup and DNS resolution.
  def generate_endpoints(count)
    base_port = rand(30_000..39_999)
    count.times.map { |i| "http://127.0.0.1:#{base_port + i}" }
  end

  it "pool_for returns the same instance for the same endpoint across random access patterns" do
    property_of {
      num_endpoints = range(1, 6)
      num_lookups = range(5, 30)
      [num_endpoints, num_lookups]
    }.check(20) do |(num_endpoints, num_lookups)|
      endpoints = generate_endpoints(num_endpoints)
      manager = AwsCrt::Http::ConnectionPoolManager.new

      # Build a random sequence of endpoint lookups
      lookup_sequence = num_lookups.times.map { endpoints.sample }

      # Record the pool returned for each endpoint on first access
      first_pool_for = {}
      lookup_sequence.each do |ep|
        pool = manager.pool_for(ep)
        if first_pool_for.key?(ep)
          # Same endpoint must return the identical object
          msg = "pool_for(#{ep.inspect}) returned a different instance " \
                "(expected object_id #{first_pool_for[ep].object_id}, " \
                "got #{pool.object_id})"
          expect(pool).to equal(first_pool_for[ep]), msg
        else
          first_pool_for[ep] = pool
        end
      end
    end
  end

  it "pool_for returns distinct instances for different endpoints" do
    property_of {
      range(2, 6)
    }.check(20) do |num_endpoints|
      endpoints = generate_endpoints(num_endpoints)
      manager = AwsCrt::Http::ConnectionPoolManager.new

      endpoint_pool_pairs = endpoints.map { |ep| [ep, manager.pool_for(ep)] }

      # Every pair of different endpoints must yield different pool objects
      endpoint_pool_pairs.combination(2).each do |(ep_a, pool_a), (ep_b, pool_b)|
        msg = "Expected distinct pools for #{ep_a.inspect} and #{ep_b.inspect}, " \
              "but got the same instance (object_id #{pool_a.object_id})"
        expect(pool_a).not_to equal(pool_b), msg
      end
    end
  end
end
