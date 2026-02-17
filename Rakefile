# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("aws_crt.gemspec")

RbSys::ExtensionTask.new("aws_crt", GEMSPEC) do |ext|
  ext.lib_dir = "lib/aws_crt"
end

namespace :crt do
  desc "Compile the CRT static libraries " \
       "(aws-c-common, aws-checksums, aws-c-cal, aws-c-io, aws-c-compression, aws-c-http)"
  task :compile do
    require_relative "ext/crt_compile"
    root_dir = File.expand_path(__dir__)
    compile_crt(root_dir)
  end

  desc "Clean CRT build artifacts"
  task :clean do
    require "fileutils"
    root_dir = File.expand_path(__dir__)
    FileUtils.rm_rf(File.join(root_dir, "crt", "build"))
    FileUtils.rm_rf(File.join(root_dir, "crt", "install"))
    puts "Cleaned CRT build and install directories"
  end
end

# Ensure CRT is built before compiling the Rust extension
task compile: "crt:compile"

# Override the default install task from bundler/gem_tasks.
# Bundler's environment (RUBYOPT, GEM_HOME, etc.) interferes with
# rb_sys during the native extension compilation that happens on
# `gem install`. We build the gem normally, then install it in a
# clean environment.
Rake::Task["install"].clear
task install: :build do
  built_gem = Dir["pkg/#{GEMSPEC.name}-#{GEMSPEC.version}*.gem"].first
  abort "Gem not found in pkg/ — did `rake build` succeed?" unless built_gem

  Bundler.with_unbundled_env do
    sh "gem install #{built_gem}"
  end
end

namespace :benchmark do
  desc "Run checksum benchmarks (vs aws-crt FFI and Zlib)"
  task checksums: :compile do
    ruby "benchmarks/checksums.rb"
  end

  desc "Run CBOR benchmarks (vs aws-sdk-core pure Ruby and cbor gem)"
  task cbor: :compile do
    ruby "benchmarks/cbor.rb"
  end

  desc "Run HTTP benchmarks (CRT vs Net::HTTP, local server)"
  task http: :compile do
    ruby "benchmarks/http.rb"
  end

  namespace :http do
    desc "Run S3 HTTP benchmarks (Net::HTTP vs CRT plugin)"
    task s3: :compile do
      ruby "benchmarks/http_s3.rb"
    end

    desc "Run DynamoDB HTTP benchmarks (Net::HTTP vs CRT plugin)"
    task dynamodb: :compile do
      ruby "benchmarks/http_dynamodb.rb"
    end

    desc "Run S3 concurrent I/O benchmarks (Net::HTTP vs CRT plugin)"
    task s3_concurrent: :compile do
      ruby "benchmarks/http_s3_concurrent.rb"
    end

    desc "Run DynamoDB concurrent I/O benchmarks (Net::HTTP vs CRT plugin)"
    task dynamodb_concurrent: :compile do
      ruby "benchmarks/http_dynamodb_concurrent.rb"
    end

    desc "Run S3 TransferManager concurrent benchmarks (Net::HTTP vs CRT plugin)"
    task s3_tm_concurrent: :compile do
      ruby "benchmarks/http_s3_tm_concurrent.rb"
    end
  end
end

desc "Run all benchmarks"
task benchmark: %i[benchmark:checksums benchmark:cbor benchmark:http]

desc "Start an interactive IRB session with the gem loaded and benchmark gems available"
task console: :compile do
  require "bundler/setup"
  # Require benchmark group gems
  Bundler.require(:benchmark)

  exec "ruby", "-I", "lib", "-r", "aws_crt", "-r", "irb", "-e", "IRB.start"
end
task c: :console

task default: %i[compile spec rubocop]
