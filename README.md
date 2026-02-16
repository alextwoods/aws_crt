# AwsCrt

High-performance native extensions for Ruby, backed by Rust and the
[AWS Common Runtime (CRT)](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html).

This gem provides:

- **CRC Checksums** — Hardware-accelerated CRC32, CRC32C, and CRC64-NVME via the CRT (SSE4.2, AVX-512, CLMUL, ARM CRC, ARM PMULL) with efficient software fallbacks.
- **CBOR Encoder/Decoder** — A fast CBOR (RFC 8949) encoder and decoder implemented in Rust, compatible with the `Aws::Cbor` interface from `aws-sdk-core`.
- **HTTP Client** — A CRT-backed HTTP/1.1 client with connection pooling, TLS, proxy support, and streaming responses. Drop-in replacement for the default `Net::HTTP` handler in the AWS SDK for Ruby V3.

The native extension is written in Rust (using [magnus](https://github.com/matsadler/magnus)
and [rb_sys](https://github.com/oxidize-rb/rb-sys)) and calls directly into
the CRT C libraries via FFI — no data copying, no Ruby FFI gem overhead.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Ruby caller                                            │
│  AwsCrt::Checksums.crc32(data)                          │
│  AwsCrt::Cbor.encode(data)                              │
│  Aws::S3::Client.new  (with CRT HTTP handler)           │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Ruby integration layer                                  │
│  lib/aws_crt/http/handler.rb     Seahorse :send handler  │
│  lib/aws_crt/http/plugin.rb      SDK plugin + config     │
│  lib/aws_crt/http/patcher.rb     auto-patch on require   │
│  lib/aws_crt/http/connection_pool_manager.rb             │
│  lib/aws_crt/http/connection_pool.rb                     │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Rust extension  (magnus / rb_sys)                       │
│  src/lib.rs               entry point + checksum FFI     │
│  src/cbor.rs              CBOR encode/decode             │
│  src/http.rs              request/response execution     │
│  src/connection_manager.rs  CRT connection pool wrapper  │
│  src/runtime.rs           shared CRT resources (once)    │
│  src/tls.rs               TLS context management         │
│  src/proxy.rs             proxy configuration            │
│  src/pool.rs              Ruby-facing pool class          │
│  src/error.rs             CRT → Ruby error translation   │
└──────────────────────────┬──────────────────────────────┘
                           │  extern "C" / FFI calls
┌──────────────────────────▼──────────────────────────────┐
│  CRT C static libraries                                  │
│  aws-c-http          HTTP/1.1 protocol + conn manager    │
│  aws-c-compression   HTTP content encoding               │
│  aws-c-io            event loops, TLS, sockets, DNS      │
│  aws-c-cal           crypto abstraction layer             │
│  aws-checksums       hardware-accelerated CRC             │
│  aws-c-common        allocators, byte buffers, logging    │
│  s2n-tls             TLS provider (Linux only)            │
└─────────────────────────────────────────────────────────┘
```

## CRT Libraries

The CRT libraries are included as git submodules under `crt/`. The full
dependency graph for HTTP support is:

```
crt/
├── CMakeLists.txt          # Top-level cmake that builds all libraries
├── aws-c-common/           # Core CRT utilities (allocators, byte buffers, logging)
├── aws-checksums/          # Hardware-accelerated CRC implementations
├── aws-c-cal/              # Crypto abstraction layer
├── aws-c-io/               # Event loops, sockets, TLS, DNS resolver
├── aws-c-compression/      # HTTP content encoding (huffman, etc.)
├── aws-c-http/             # HTTP/1.1 protocol and connection manager
└── s2n-tls/                # TLS provider (Linux only; macOS uses Security.framework)
```

The build order follows the CRT dependency graph:

```
aws-c-common
├── aws-checksums
├── aws-c-cal
│   └── aws-c-io  (+ s2n-tls on Linux)
│       ├── aws-c-compression
│       └── aws-c-http
```

### How they're built

The build is driven by cmake and orchestrated through Rake:

1. `rake crt:compile` runs cmake to configure and build all CRT C libraries as
   static archives (`.a` files) into `crt/install/`. The cmake project
   (`crt/CMakeLists.txt`) adds libraries in dependency order: `aws-c-common`
   first, then `aws-checksums`, `aws-c-cal`, `s2n-tls` (Linux only),
   `aws-c-io`, `aws-c-compression`, and `aws-c-http`. Shared libraries and
   tests are disabled — only the static libraries and headers are installed.

2. `rake compile` depends on `crt:compile`, so the CRT libraries are always
   built before the Rust extension. The Rust `build.rs` script locates the
   pre-built static libraries under `crt/install/lib/` and tells Cargo to
   link them into the final `.bundle`/`.so` in the correct dependency order
   (dependents first: `aws-c-http` → `aws-c-compression` → `aws-c-io` →
   `aws-c-cal` → `aws-checksums` → `aws-c-common`). On Linux, `s2n-tls`
   and `libcrypto` are also linked. On macOS, Security.framework and
   CoreFoundation.framework are linked for TLS and platform services.

3. The Rust extension (`ext/aws_crt/`) uses `rb_sys` and `magnus` to bridge
   between Ruby and Rust. The Rust code declares `extern "C"` bindings to
   CRT checksum functions (in `src/lib.rs`) and CRT HTTP APIs (in
   `src/http.rs`, `src/connection_manager.rs`, `src/runtime.rs`, `src/tls.rs`,
   `src/proxy.rs`). The HTTP path releases the GVL during blocking I/O so
   other Ruby threads can run concurrently.

### How they're included in the gem

When building the gem for distribution (`rake build`), the gemspec
automatically includes the pre-built CRT static libraries and headers from
`crt/install/` if they exist. This means end users installing a pre-built
platform gem don't need cmake installed — only Rust (for the native extension
compilation via `rb_sys`).

For source gem installs, the full build chain runs: cmake builds the CRT
libraries, then Cargo compiles the Rust extension and statically links them.

## CBOR Performance

The CBOR encoder and decoder are optimized for minimal overhead on the
Ruby-to-Rust boundary. Key optimizations:

### Encoding

- **Raw `rb_sys` API** — Bypasses magnus wrapper overhead for type checking
  and value extraction. Uses `FIXNUM_P`/`FIX2LONG` for integers,
  `RSTRING_PTR`/`RSTRING_LEN` for strings, `RARRAY_CONST_PTR` for arrays,
  and `rb_hash_foreach` for hash iteration — all avoiding Ruby method calls
  and intermediate allocations.
- **Cached class references** — `Time`, `BigDecimal`, and `Tagged` class
  VALUEs are resolved once at init and stored in statics, avoiding repeated
  constant lookups during encoding.
- **Module-level `encode`/`decode` functions** — `AwsCrt::Cbor.encode(data)`
  and `AwsCrt::Cbor.decode(bytes)` skip Ruby object allocation entirely,
  operating on a stack-allocated `Vec<u8>` buffer.
- **Auto float precision** — Floats that can be represented exactly as
  single-precision are encoded as 4 bytes instead of 8, matching the CBOR
  gem's behavior and reducing output size.

### Decoding

- **Inlined fast paths** — Small integers (0–23, -1–-24) and short text
  strings (length < 24) are decoded inline in the main dispatch loop,
  avoiding function call overhead for the most common CBOR types.
- **Inlined float decode** — Single and double precision floats are decoded
  directly in the `decode_value` match arm rather than through helper
  functions.
- **Direct Ruby object creation** — Uses `rb_float_new`, `LONG2FIX`,
  `rb_enc_str_new`, `rb_ary_new_capa`, `rb_hash_new_capa`, and
  `rb_hash_aset` directly, bypassing magnus value conversion.
- **Inlined map key decode** — Hash keys (typically short text strings) are
  decoded inline in the map decode loop, avoiding a function call per
  key-value pair.

### Benchmark results

Measured on Apple M3 Pro, Ruby 3.3.3, comparing against the
[cbor](https://rubygems.org/gems/cbor) C extension gem and Ruby's built-in
JSON:

**Encode** (iterations/second, higher is better):

| Payload | AwsCrt::Cbor.encode | CBOR gem (C) | JSON.dump | Aws::Cbor (pure Ruby) |
|---------|--------------------:|-------------:|----------:|----------------------:|
| Small (3-key int map) | 6.67M | 4.49M | 4.43M | 317k |
| Medium (50-key string map) | 618k | 722k | 608k | 23k |
| Large (nested mixed) | 45.2k | 47.8k | 44.3k | 1.3k |

**Decode** (iterations/second, higher is better):

| Payload | AwsCrt::Cbor.decode | CBOR gem (C) | JSON.parse | Aws::Cbor (pure Ruby) |
|---------|--------------------:|-------------:|-----------:|----------------------:|
| Small (3-key int map) | 3.45M | 2.45M | 3.97M | 260k |
| Medium (50-key string map) | 150k | 148k | 210k | 17k |
| Large (nested mixed) | 10.5k | 12.7k | 21.8k | 809 |

Encoding is 1.5x faster than the CBOR C gem on small payloads and
competitive on larger ones. Decoding consistently beats the CBOR C gem and
is within 1.2–2x of JSON (which benefits from a monolithic C state machine
parser with less per-value function dispatch overhead).

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
(Note, if you get errors you may need to do `rake clobber build install`)

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
bundle exec rake benchmark          # checksums
bundle exec rake benchmark:cbor     # CBOR encode/decode
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

### Checksums

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

### CBOR

The CBOR encoder and decoder follow the same public interface as
`Aws::Cbor::Encoder` and `Aws::Cbor::Decoder` from
[aws-sdk-core](https://github.com/aws/aws-sdk-ruby), making them a
drop-in replacement.

#### Module functions (recommended)

The fastest way to encode and decode — no object allocation overhead:

```ruby
require "aws_crt"

data = { "name" => "Alice", "age" => 30, "scores" => [95, 87, 92] }

# Encode
encoded = AwsCrt::Cbor.encode(data)
# => CBOR binary string

# Decode
decoded = AwsCrt::Cbor.decode(encoded)
# => {"name"=>"Alice", "age"=>30, "scores"=>[95, 87, 92]}
```

#### Encoder/Decoder classes

For compatibility with the `Aws::Cbor` interface, or when you need to
encode multiple values into a single buffer:

```ruby
# Encode
encoder = AwsCrt::Cbor::Encoder.new
encoder.add({ "id" => 1 })
encoder.add({ "id" => 2 })
bytes = encoder.bytes

# Decode
decoder = AwsCrt::Cbor::Decoder.new(encoded)
decoded = decoder.decode
```

#### Supported types

| Ruby type    | CBOR encoding                          |
|--------------|----------------------------------------|
| Integer      | Unsigned/negative integer, or bignum tag (2/3) for arbitrary precision |
| Float        | Single or double precision (auto-selected) |
| String       | Text string (UTF-8) or byte string (BINARY encoding) |
| Symbol       | Text string                            |
| Array        | Array                                  |
| Hash         | Map                                    |
| true/false   | Simple value                           |
| nil          | Simple value (null)                    |
| Time         | Tag 1 (epoch-based date/time)          |
| BigDecimal   | Tag 4 (decimal fraction)               |
| Tagged       | Tag with arbitrary value               |

#### Error classes

All errors inherit from `AwsCrt::Cbor::Error`:

- `OutOfBytesError` — input buffer exhausted during decode
- `ExtraBytesError` — trailing bytes after a complete CBOR item
- `UnknownTypeError` — encoder encountered an unsupported Ruby type
- `UnexpectedBreakCodeError` — break code outside indefinite-length context
- `UnexpectedAdditionalInformationError` — invalid additional info field

### HTTP Client

#### Auto-patch (recommended)

Replace the default `Net::HTTP` handler on all AWS service clients with a single require:

```ruby
require "aws_crt/http"

# All AWS clients now use the CRT HTTP client automatically
client = Aws::S3::Client.new(region: "us-east-1")
```

This patches both currently-loaded and future-loaded service clients.

#### Manual plugin registration

For more control, register the plugin on specific clients:

```ruby
require "aws_crt/http/plugin"

Aws::S3::Client.add_plugin(AwsCrt::Http::Plugin)
client = Aws::S3::Client.new(region: "us-east-1")
```

#### Configuration options

The plugin accepts the same options as the SDK's default HTTP handler:

| Option | Default | Description |
|--------|---------|-------------|
| `http_open_timeout` | 60 | Connection timeout in seconds |
| `http_read_timeout` | 60 | Read timeout in seconds |
| `ssl_verify_peer` | true | Verify TLS certificates |
| `ssl_ca_bundle` | nil | Path to custom CA bundle |
| `http_proxy` | nil | Proxy config hash (`{host:, port:, username:, password:}`) |
| `max_connections` | 25 | Max concurrent connections per endpoint |
| `max_connection_idle_ms` | 60000 | Idle connection timeout in milliseconds |

#### Direct pool usage

You can also use the connection pool directly without the SDK:

```ruby
require "aws_crt"

pool = AwsCrt::Http::ConnectionPool.new("https://example.com")
status, headers, body = pool.request("GET", "/path", [["Host", "example.com"]])

# Streaming response
pool.request("GET", "/large", [["Host", "example.com"]]) do |chunk|
  # process each chunk as it arrives
end
```

#### Error classes

HTTP errors inherit from `AwsCrt::Http::Error`:

- `ConnectionError` — DNS failures, connection refused
- `TimeoutError` — connect or read timeout exceeded
- `TlsError` — TLS handshake or certificate failures
- `ProxyError` — proxy connection or authentication failures

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

The AWS CRT libraries are licensed under [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).

## Code of Conduct

Everyone interacting in this project's codebases, issue trackers, chat rooms,
and mailing lists is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
