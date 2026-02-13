# frozen_string_literal: true

require_relative "lib/aws_crt/version"

Gem::Specification.new do |spec|
  spec.name = "aws_crt"
  spec.version = AwsCrt::VERSION
  spec.authors = ["Alex Woods"]
  spec.email = ["alexwoo@amazon.com"]

  spec.summary = "Ruby bindings for AWS CRT checksum functions"
  spec.description = "High-performance CRC32, CRC32C, and CRC64-NVME checksums " \
                     "using the AWS Common Runtime (CRT) with hardware acceleration, " \
                     "exposed to Ruby via a Rust native extension."
  spec.homepage = "https://github.com/awslabs/aws_crt"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"
  spec.required_rubygems_version = ">= 3.3.11"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ benchmarks/ .git .vscode appveyor Gemfile])
    end
  end

  # Include pre-built CRT static libraries and headers if they exist.
  # These are produced by `rake crt:compile` and allow the gem to be
  # installed without cmake.
  crt_install = File.join(__dir__, "crt", "install")
  if Dir.exist?(crt_install)
    Dir.glob("crt/install/**/*", base: __dir__).each do |f|
      spec.files << f unless File.directory?(File.join(__dir__, f))
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/aws_crt/Cargo.toml"]
end
