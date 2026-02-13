# frozen_string_literal: true

# Unit tests for the AwsCrt::Http error hierarchy.
#
# Requirements: 10.2 — THE module SHALL define a clear error hierarchy:
#   AwsCrt::Http::Error as the base, with subclasses ConnectionError,
#   TimeoutError, TlsError, and ProxyError.

RSpec.describe "AwsCrt::Http error hierarchy" do
  describe "AwsCrt::Http::Error" do
    it "is defined under AwsCrt::Http" do
      expect(AwsCrt::Http::Error).to be_a(Class)
    end

    it "inherits from AwsCrt::Error" do
      expect(AwsCrt::Http::Error.superclass).to eq(AwsCrt::Error)
    end

    it "inherits from StandardError (via AwsCrt::Error)" do
      expect(AwsCrt::Http::Error.ancestors).to include(StandardError)
    end

    it "can be instantiated with a message" do
      error = AwsCrt::Http::Error.new("something went wrong")
      expect(error.message).to eq("something went wrong")
    end

    it "can be raised and rescued as AwsCrt::Error" do
      expect {
        raise AwsCrt::Http::Error, "http error"
      }.to raise_error(AwsCrt::Error)
    end
  end

  {
    "ConnectionError" => AwsCrt::Http::ConnectionError,
    "TimeoutError" => AwsCrt::Http::TimeoutError,
    "TlsError" => AwsCrt::Http::TlsError,
    "ProxyError" => AwsCrt::Http::ProxyError
  }.each do |name, klass|
    describe "AwsCrt::Http::#{name}" do
      it "is defined under AwsCrt::Http" do
        expect(klass).to be_a(Class)
      end

      it "inherits from AwsCrt::Http::Error" do
        expect(klass.superclass).to eq(AwsCrt::Http::Error)
      end

      it "can be rescued as AwsCrt::Http::Error" do
        expect {
          raise klass, "#{name} occurred"
        }.to raise_error(AwsCrt::Http::Error)
      end

      it "can be rescued as AwsCrt::Error" do
        expect {
          raise klass, "#{name} occurred"
        }.to raise_error(AwsCrt::Error)
      end

      it "preserves its message" do
        error = klass.new("detail")
        expect(error.message).to eq("detail")
      end
    end
  end
end
