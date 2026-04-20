# frozen_string_literal: true

# Ractor integration tests for AwsCrt::RactorTest.
#
# Verifies that a minimal Rust struct using the `frozen_shareable`
# TypedData flag can be frozen, shared across Ractors, and used
# for concurrent operations from multiple Ractors in parallel.

RSpec.describe "AwsCrt::RactorTest Ractor support" do
  describe "basic functionality" do
    it "creates an instance with a name" do
      obj = AwsCrt::RactorTest.new("hello")
      expect(obj.name).to eq("hello")
    end

    it "starts with counter at 0" do
      obj = AwsCrt::RactorTest.new("test")
      expect(obj.counter).to eq(0)
    end

    it "increments the counter" do
      obj = AwsCrt::RactorTest.new("test")
      expect(obj.increment).to eq(1)
      expect(obj.increment).to eq(2)
      expect(obj.counter).to eq(2)
    end
  end

  describe "Ractor.shareable?" do
    it "is shareable when frozen" do
      obj = AwsCrt::RactorTest.new("frozen-test")
      obj.freeze
      expect(Ractor.shareable?(obj)).to be true
    end

    it "is not shareable when not frozen" do
      obj = AwsCrt::RactorTest.new("unfrozen-test")
      expect(Ractor.shareable?(obj)).to be false
    end

    it "can be made shareable with Ractor.make_shareable" do
      obj = AwsCrt::RactorTest.new("make-shareable-test")
      Ractor.make_shareable(obj)
      expect(Ractor.shareable?(obj)).to be true
      expect(obj.frozen?).to be true
    end
  end

  describe "single Ractor usage" do
    it "can read name from a non-main Ractor" do
      obj = AwsCrt::RactorTest.new("ractor-name")
      obj.freeze

      result = Ractor.new(obj) do |o|
        o.name
      end.value

      expect(result).to eq("ractor-name")
    end

    it "can increment counter from a non-main Ractor" do
      obj = AwsCrt::RactorTest.new("ractor-counter")
      obj.freeze

      result = Ractor.new(obj) do |o|
        o.increment
        o.increment
        o.counter
      end.value

      expect(result).to eq(2)
    end
  end

  describe "multi-Ractor parallel usage" do
    it "shares a single instance across multiple Ractors" do
      obj = AwsCrt::RactorTest.new("shared")
      obj.freeze

      ractor_count = 4
      increments_per_ractor = 10

      ractors = ractor_count.times.map do |i|
        Ractor.new(obj, increments_per_ractor, i) do |o, n, idx|
          n.times { o.increment }
          [idx, o.counter]
        end
      end

      results = ractors.map(&:value)

      # All Ractors should have completed
      expect(results.size).to eq(ractor_count)

      # The final counter should reflect all increments from all Ractors.
      # Since all Ractors share the same object, the counter should be
      # at least ractor_count * increments_per_ractor (exactly, since
      # Mutex serializes access).
      expect(obj.counter).to eq(ractor_count * increments_per_ractor)
    end

    it "reads name consistently from multiple Ractors" do
      obj = AwsCrt::RactorTest.new("consistent-name")
      obj.freeze

      ractors = 4.times.map do |i|
        Ractor.new(obj, i) do |o, idx|
          [idx, o.name]
        end
      end

      results = ractors.map(&:value)
      results.each do |idx, name|
        expect(name).to eq("consistent-name"),
          "Ractor #{idx} got name '#{name}' instead of 'consistent-name'"
      end
    end
  end

  describe "error handling" do
    it "cannot send an unfrozen instance to a Ractor" do
      obj = AwsCrt::RactorTest.new("unfrozen")

      # Sending a non-shareable object to a Ractor raises an error.
      # The exact error class depends on the Ruby internals — it may be
      # Ractor::IsolationError or TypeError (when alloc_func is undefined).
      expect {
        Ractor.new(obj) do |o|
          o.name
        end.value
      }.to raise_error(StandardError)
    end
  end
end
