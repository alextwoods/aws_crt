# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("aws_crt_s3_client.gemspec")

RbSys::ExtensionTask.new("aws_crt_s3_client", GEMSPEC) do |ext|
  ext.lib_dir = "lib/aws_crt_s3_client"
end

namespace :crt do
  desc "Compile the CRT static libraries (aws-checksums, aws-c-common)"
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

desc "Run checksum benchmarks (vs aws-crt FFI and Zlib)"
task benchmark: :compile do
  ruby "benchmarks/checksums.rb"
end

task default: %i[compile spec rubocop]
