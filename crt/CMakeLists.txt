cmake_minimum_required(VERSION 3.9...3.31)
project(aws-crt C)

message(STATUS "CMake ${CMAKE_VERSION}")

option(BUILD_SHARED_LIBS "Build shared libraries" OFF)

# Use aws-c-common's CMake modules
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/aws-c-common/cmake")

include(AwsFindPackage)

set(IN_SOURCE_BUILD ON)
set(BUILD_TESTING OFF)

# Build order follows the CRT dependency graph:
#
#   aws-c-common
#   ├── aws-checksums
#   ├── aws-c-cal
#   │   └── aws-c-io  (+ s2n-tls on Linux)
#   │       ├── aws-c-compression
#   │       └── aws-c-http

# Foundation
add_subdirectory(aws-c-common)
add_subdirectory(aws-checksums)

# Crypto abstraction layer
add_subdirectory(aws-c-cal)

# TLS provider: s2n-tls on Linux, Security.framework on macOS (handled by aws-c-io)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    add_subdirectory(s2n-tls)
endif()

# I/O and event loops
add_subdirectory(aws-c-io)

# HTTP stack
add_subdirectory(aws-c-compression)
add_subdirectory(aws-c-http)
