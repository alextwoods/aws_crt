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

task default: %i[compile spec rubocop]
