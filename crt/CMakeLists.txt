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
#   ├── aws-c-cal  (+ aws-lc on Linux)
#   │   └── aws-c-io  (+ s2n-tls on Linux)
#   │       ├── aws-c-compression
#   │       └── aws-c-http

# Foundation
add_subdirectory(aws-c-common)
add_subdirectory(aws-checksums)

# On Linux, aws-c-cal needs libcrypto (from AWS-LC) and s2n-tls needs
# libcrypto at configure time.  Following the aws-crt-ffi pattern we
# prebuild both dependencies so their artifacts are visible to the
# regular add_subdirectory() calls that follow.
if (UNIX AND NOT APPLE)
    include(AwsPrebuildDependency)

    set(AWSLC_CMAKE_ARGUMENTS
        -DDISABLE_GO=ON
        -DDISABLE_PERL=ON
        -DBUILD_LIBSSL=OFF
        -DBUILD_TESTING=OFF
    )

    if (CMAKE_C_COMPILER_ID MATCHES "GNU" AND CMAKE_C_COMPILER_VERSION VERSION_LESS "5.0")
        list(APPEND AWSLC_CMAKE_ARGUMENTS -DMY_ASSEMBLER_IS_TOO_OLD_FOR_512AVX=ON)
    endif()

    # s2n-tls uses libcrypto during its configuration, so we need to
    # prebuild aws-lc first.
    aws_prebuild_dependency(
        DEPENDENCY_NAME AWSLC
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/aws-lc
        CMAKE_ARGUMENTS ${AWSLC_CMAKE_ARGUMENTS}
    )

    set(SEARCH_LIBCRYPTO OFF CACHE BOOL "Let s2n-tls use libcrypto from AWS-LC.")

    # Prebuild s2n-tls so it can find the just-built libcrypto.
    aws_prebuild_dependency(
        DEPENDENCY_NAME S2N
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/s2n-tls
        CMAKE_ARGUMENTS
            -DUNSAFE_TREAT_WARNINGS_AS_ERRORS=OFF
            -DBUILD_TESTING=OFF
    )
endif()

# Crypto abstraction layer
add_subdirectory(aws-c-cal)

# I/O and event loops
add_subdirectory(aws-c-io)

# HTTP stack
add_subdirectory(aws-c-compression)
add_subdirectory(aws-c-http)
