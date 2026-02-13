# frozen_string_literal: true

require "aws_crt/s3/credentials"

RSpec.describe AwsCrt::S3::Credentials do
  it "stores access_key_id, secret_access_key, and session_token" do
    creds = described_class.new(
      access_key_id: "AKID",
      secret_access_key: "secret",
      session_token: "token"
    )
    expect(creds.access_key_id).to eq("AKID")
    expect(creds.secret_access_key).to eq("secret")
    expect(creds.session_token).to eq("token")
  end

  it "defaults session_token to nil" do
    creds = described_class.new(
      access_key_id: "AKID",
      secret_access_key: "secret"
    )
    expect(creds.session_token).to be_nil
  end
end

RSpec.describe AwsCrt::S3::StaticCredentialProvider do
  it "returns the same credentials object on every call" do
    creds = AwsCrt::S3::Credentials.new(
      access_key_id: "AKID",
      secret_access_key: "secret"
    )
    provider = described_class.new(creds)

    expect(provider.credentials).to be(creds)
    expect(provider.credentials).to be(creds)
  end

  it "works with any duck-typed credentials object" do
    duck_creds = Struct.new(:access_key_id, :secret_access_key, :session_token)
                       .new("AKID", "secret", nil)
    provider = described_class.new(duck_creds)

    expect(provider.credentials.access_key_id).to eq("AKID")
  end
end
