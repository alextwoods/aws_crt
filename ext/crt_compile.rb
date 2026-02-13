# frozen_string_literal: true

require "etc"
require "mkmf"
require "fileutils"
require "shellwords"

CMAKE_PATH = find_executable("cmake3") || find_executable("cmake")
abort "Missing cmake - please install cmake (https://cmake.org/)" unless CMAKE_PATH
CMAKE = File.basename(CMAKE_PATH)

def cmake_version
  version_str = `#{CMAKE} --version`
  match = /(\d+)\.(\d+)\.(\d+)/.match(version_str)
  [match[1].to_i, match[2].to_i, match[3].to_i]
end

CMAKE_VERSION = cmake_version

def cmake_has_parallel_flag?
  (CMAKE_VERSION <=> [3, 12]) >= 0
end

def run_cmd(args)
  cmd_str = Shellwords.join(args)
  puts cmd_str
  system(*args) || raise("Error running: #{cmd_str}")
end

def compile_crt(root_dir)
  crt_dir = File.join(root_dir, "crt")
  build_dir = File.join(crt_dir, "build")
  install_dir = File.join(crt_dir, "install")

  FileUtils.mkdir_p(build_dir)

  build_type = "RelWithDebInfo"

  config_cmd = [
    CMAKE,
    "-S", crt_dir,
    "-B", build_dir,
    "-DCMAKE_INSTALL_PREFIX=#{install_dir}",
    "-DCMAKE_BUILD_TYPE=#{build_type}",
    "-DBUILD_TESTING=OFF",
    "-DBUILD_SHARED_LIBS=OFF"
  ]

  build_cmd = [
    CMAKE,
    "--build", build_dir,
    "--target", "install",
    "--config", build_type
  ]

  if cmake_has_parallel_flag?
    build_cmd.append("--parallel")
    build_cmd.append(Etc.nprocessors.to_s)
  end

  run_cmd(config_cmd)
  run_cmd(build_cmd)

  puts "CRT libraries installed to #{install_dir}"
  install_dir
end
