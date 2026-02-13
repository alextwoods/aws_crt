# AwsCrt

High-performance CRC checksum functions for Ruby, backed by the
[AWS Common Runtime (CRT)](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html).
The CRT provides hardware-accelerated implementations (SSE4.2, AVX-512, CLMUL,
ARM CRC, ARM PMULL) with efficient software fallbacks.

This gem exposes three checksum algorithms:

- **CRC32** — Ethernet/gzip variant
- **CRC32C** — Castagnoli/iSCSI variant
- **CRC64-NVME** — CRC64-Rocksoft variant

The native extension is written in Rust (using [magnus](https://github.com/matsadler/magnus)
and [rb_sys](https://github.com/oxidize-rb/rb-sys)) and calls directly into
the CRT C libraries via FFI — no data copying, no Ruby FFI gem overhead.

## Architecture

```
┌──────────────┐
│  Ruby caller  │
└──────┬───────┘
       │  AwsCrt::Checksums.crc32(data)
┌──────▼───────┐
│ Rust extension│  (magnus / rb_sys)
│  src/lib.rs   │  reads Ruby string bytes in-place
└──────┬───────┘
       │  extern "C" call
┌──────▼───────┐
│ aws-checksums │  CRT static library (hardware-accelerated)
│ aws-c-common  │
└──────────────┘
```

The CRT libraries (`aws-checksums` and its dependency `aws-c-common`) are
included as git submodules under `crt/` and built as static libraries with
cmake. The Rust `build.rs` links them into the final `.bundle`/`.so` at
compile time.

## Prerequisites

- Ruby >= 3.0
- Rust (stable) — install via [rustup](https://rustup.rs/)
- CMake >= 3.9
- A C compiler (clang or gcc)
- Bundler

## Setup

Clone the repo with submodules:

```sh
git clone --recurse-submodules https://github.com/awslabs/aws_crt.git
cd aws_crt
bundle install
```

If you already cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

## Common Commands

### Build everything (CRT libs + Rust extension)

```sh
bundle exec rake compile
```

This runs `crt:compile` first (cmake builds the static CRT libraries into
`crt/install/`), then compiles the Rust extension and places the resulting
`.bundle`/`.so` in `lib/aws_crt/`.

### Run tests

```sh
bundle exec rake spec
```

### Run the linter

```sh
bundle exec rake rubocop
```

### Run the full default task (compile + spec + rubocop)

```sh
bundle exec rake
```

### Run benchmarks

```sh
bundle exec rake benchmark
```

### Build the CRT libraries only

```sh
bundle exec rake crt:compile
```

### Clean CRT build artifacts

```sh
bundle exec rake crt:clean
```

### Build the gem for distribution

```sh
bundle exec rake build
```

This produces a `.gem` file in `pkg/`. For platform gems with pre-built
binaries, the CRT static libraries and compiled Rust extension are included
so that end users don't need cmake or Rust installed.

### Install locally

```sh
bundle exec rake install
```

## Usage

```ruby
require "aws_crt"

data = "Hello world"

AwsCrt::Checksums.crc32(data)        # => 2346098258
AwsCrt::Checksums.crc32c(data)       # => 1924472696
AwsCrt::Checksums.crc64nvme(data)    # => 4098937361808829147

# All three methods accept an optional second argument to continue
# a running checksum (defaults to 0):
part1 = AwsCrt::Checksums.crc32("Hello ")
AwsCrt::Checksums.crc32("world", part1)  # same as crc32("Hello world")
```

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

The AWS CRT libraries are licensed under [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).

## Code of Conduct

Everyone interacting in this project's codebases, issue trackers, chat rooms,
and mailing lists is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
