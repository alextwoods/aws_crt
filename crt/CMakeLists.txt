cmake_minimum_required(VERSION 3.9...3.31)
project(aws-crt-checksums C)

message(STATUS "CMake ${CMAKE_VERSION}")

option(BUILD_SHARED_LIBS "Build shared libraries" OFF)

# Use aws-c-common's CMake modules
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/aws-c-common/cmake")

include(AwsFindPackage)

set(IN_SOURCE_BUILD ON)
set(BUILD_TESTING OFF)

# Build aws-c-common (dependency of aws-checksums)
add_subdirectory(aws-c-common)

# Build aws-checksums
add_subdirectory(aws-checksums)
