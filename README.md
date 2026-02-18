# AwsCrt

High-performance native extensions for Ruby, backed by Rust and the
[AWS Common Runtime (CRT)](https://docs.aws.amazon.com/sdkref/latest/guide/common-runtime.html).

This gem provides:

- **CRC Checksums** — Hardware-accelerated CRC32, CRC32C, and CRC64-NVME via the CRT (SSE4.2, AVX-512, CLMUL, ARM CRC, ARM PMULL) with efficient software fallbacks.
- **CBOR Encoder/Decoder** — A fast CBOR (RFC 8949) encoder and decoder implemented in Rust, compatible with the `Aws::Cbor` interface from `aws-sdk-core`.
- **HTTP Client** — A CRT-backed HTTP/1.1 client with connection pooling, TLS, proxy support, and streaming responses. Drop-in replacement for the default `Net::HTTP` handler in the AWS SDK for Ruby V3.
- **S3 Client** — A standalone high-performance S3 client backed by the CRT's `aws-c-s3` meta-request system. Provides automatic request splitting (parallel multipart upload/download), per-chunk retries, and parallel file I/O for significantly higher throughput on large object transfers.

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
│  AwsCrt::S3::Client.new  (standalone CRT S3 client)     │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Ruby integration layer                                  │
│  lib/aws_crt/http/handler.rb     Seahorse :send handler  │
│  lib/aws_crt/http/plugin.rb      SDK plugin + config     │
│  lib/aws_crt/http/patcher.rb     auto-patch on require   │
│  lib/aws_crt/http/connection_pool_manager.rb             │
│  lib/aws_crt/http/connection_pool.rb                     │
│  lib/aws_crt/s3/client.rb        S3 client wrapper       │
│  lib/aws_crt/s3/response.rb      S3 response object      │
│  lib/aws_crt/s3/errors.rb        S3 error hierarchy      │
└──────────────────────────┬──────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Rust extension  (magnus / rb_sys)                       │
│  src/lib.rs               entry point + checksum FFI     │
│  src/cbor.rs              CBOR encode/decode             │
│  src/http.rs              request/response execution     │
│  src/connection_manager.rs  CRT connection pool wrapper  │
│  src/s3_client.rs         CRT S3 client wrapper          │
│  src/s3_request.rs        S3 meta-request execution      │
│  src/s3_ruby.rs           Ruby-facing S3 class           │
│  src/credentials.rs       CRT credentials bridge         │
│  src/signing.rs           CRT signing config             │
│  src/runtime.rs           shared CRT resources (once)    │
│  src/tls.rs               TLS context management         │
│  src/proxy.rs             proxy configuration            │
│  src/pool.rs              Ruby-facing pool class          │
│  src/error.rs             CRT → Ruby error translation   │
└──────────────────────────┬──────────────────────────────┘
                           │  extern "C" / calls
┌──────────────────────────▼──────────────────────────────┐
│  CRT C static libraries                                  │
│  aws-c-s3            S3 meta-requests + parallel I/O     │
│  aws-c-auth          credentials + SigV4 signing         │
│  aws-c-sdkutils      SDK utility functions               │
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
dependency graph for HTTP and S3 support is:

```
crt/
├── CMakeLists.txt          # Top-level cmake that builds all libraries
├── aws-c-common/           # Core CRT utilities (allocators, byte buffers, logging)
├── aws-checksums/          # Hardware-accelerated CRC implementations
├── aws-c-cal/              # Crypto abstraction layer
├── aws-c-io/               # Event loops, sockets, TLS, DNS resolver
├── aws-c-compression/      # HTTP content encoding (huffman, etc.)
├── aws-c-http/             # HTTP/1.1 protocol and connection manager
├── aws-c-sdkutils/         # SDK utility functions
├── aws-c-auth/             # Credentials and SigV4 signing
├── aws-c-s3/               # S3 meta-requests, parallel I/O, request splitting
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
├── aws-c-sdkutils
├── aws-c-auth  (depends on aws-c-sdkutils, aws-c-cal, aws-c-http)
└── aws-c-s3    (depends on aws-c-auth, aws-checksums)
```

### How they're built

The build is driven by cmake and orchestrated through Rake:

1. `rake crt:compile` runs cmake to configure and build all CRT C libraries as
   static archives (`.a` files) into `crt/install/`. The cmake project
   (`crt/CMakeLists.txt`) adds libraries in dependency order: `aws-c-common`
   first, then `aws-checksums`, `aws-c-cal`, `s2n-tls` (Linux only),
   `aws-c-io`, `aws-c-compression`, `aws-c-http`, `aws-c-sdkutils`,
   `aws-c-auth`, and `aws-c-s3`. Shared libraries and tests are disabled —
   only the static libraries and headers are installed.

2. `rake compile` depends on `crt:compile`, so the CRT libraries are always
   built before the Rust extension. The Rust `build.rs` script locates the
   pre-built static libraries under `crt/install/lib/` and tells Cargo to
   link them into the final `.bundle`/`.so` in the correct dependency order
   (dependents first: `aws-c-s3` → `aws-c-auth` → `aws-c-sdkutils` →
   `aws-c-http` → `aws-c-compression` → `aws-c-io` → `aws-c-cal` →
   `aws-checksums` → `aws-c-common`). On Linux, `s2n-tls` and `libcrypto`
   are also linked. On macOS, Security.framework and CoreFoundation.framework
   are linked for TLS and platform services.

3. The Rust extension (`ext/aws_crt/`) uses `rb_sys` and `magnus` to bridge
   between Ruby and Rust. The Rust code declares `extern "C"` bindings to
   CRT checksum functions (in `src/lib.rs`), CRT HTTP APIs (in `src/http.rs`,
   `src/connection_manager.rs`, `src/runtime.rs`, `src/tls.rs`, `src/proxy.rs`),
   and CRT S3 APIs (in `src/s3_client.rs`, `src/s3_request.rs`,
   `src/credentials.rs`, `src/signing.rs`). Both the HTTP and S3 paths release
   the GVL during blocking I/O so other Ruby threads can run concurrently.

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
bundle exec rake benchmark              # checksums + CBOR + HTTP (local)
bundle exec rake benchmark:cbor         # CBOR encode/decode
bundle exec rake benchmark:http         # HTTP (local test server)
bundle exec rake benchmark:http:s3      # S3 get/put (benchmark-ips)
bundle exec rake benchmark:http:dynamodb            # DynamoDB get/put (benchmark-ips)
bundle exec rake benchmark:http:s3_concurrent       # S3 concurrent I/O
bundle exec rake benchmark:http:dynamodb_concurrent # DynamoDB concurrent I/O
bundle exec ruby benchmarks/s3.rb       # CRT S3 client vs SDK (benchmark-ips)
```

#### Service benchmarks (S3 & DynamoDB)

The `benchmark:http:s3` and `benchmark:http:dynamodb` tasks use `benchmark-ips`
to compare single-threaded request throughput between the default `Net::HTTP`
handler and the CRT HTTP plugin. All operations run in a single `Benchmark.ips`
block so that `compare!` produces a meaningful cross-comparison.

| ENV var | Default | Description |
|---------|---------|-------------|
| `BENCH_S3_BUCKET` | `test-bucket-alexwoo-2` | S3 bucket for test objects |
| `BENCH_DYNAMODB_TABLE` | *(see source)* | DynamoDB table (partition key `id`, String) |

#### Concurrent I/O benchmarks

The `_concurrent` variants use `concurrent-ruby` with a fixed thread pool to
measure throughput under parallel load — closer to real-world SDK usage than
single-threaded `benchmark-ips`.

| ENV var | Default | Description |
|---------|---------|-------------|
| `BENCH_TOTAL_CALLS` | `1000` | Total number of API calls to make |
| `BENCH_THREADS` | `8` | Thread pool size |
| `BENCH_S3_BUCKET` | `test-bucket-alexwoo-2` | S3 bucket for test objects |
| `BENCH_DYNAMODB_TABLE` | *(see source)* | DynamoDB table (partition key `id`, String) |

Example with custom concurrency settings:

```sh
BENCH_THREADS=16 BENCH_TOTAL_CALLS=5000 bundle exec rake benchmark:http:s3_concurrent
```

#### CRT S3 client benchmarks

The `benchmarks/s3.rb` script compares the standalone CRT S3 client
(`AwsCrt::S3::Client`) against the standard `Aws::S3::Client` for upload and
download throughput. It tests both in-memory and file I/O paths at 1MB and
100MB object sizes.

| ENV var | Default | Description |
|---------|---------|-------------|
| `BENCH_S3_BUCKET` | `crt-s3-benchmark` | S3 bucket for test objects |
| `BENCH_S3_REGION` | `us-east-1` | AWS region |

```sh
BENCH_S3_BUCKET=my-bucket BENCH_S3_REGION=us-west-2 bundle exec ruby benchmarks/s3.rb
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

### S3 Client

The CRT S3 client is a standalone high-performance client at `AwsCrt::S3::Client`.
Unlike the HTTP client (which is a drop-in Seahorse handler), the S3 client
wraps the CRT's meta-request system directly — giving you automatic request
splitting, per-chunk retries, and parallel file I/O out of the box.

#### Creating a client

```ruby
require "aws_crt/s3"

# With an AWS SDK credential provider (recommended)
provider = Aws::SharedCredentials.new
client = AwsCrt::S3::Client.new(
  region: "us-east-1",
  credentials: provider
)

# With a credentials object
creds = AwsCrt::S3::Credentials.new(
  access_key_id: "AKIA...",
  secret_access_key: "secret",
  session_token: "token"  # optional
)
client = AwsCrt::S3::Client.new(
  region: "us-east-1",
  credentials: creds
)

# With raw strings (backward compatible)
client = AwsCrt::S3::Client.new(
  region: "us-east-1",
  access_key_id: "AKIA...",
  secret_access_key: "secret"
)
```

The `:credentials` parameter accepts either:
- A credential provider (any object with a `credentials` method that returns a credentials object). This is the recommended approach — credentials are resolved fresh on every request, so temporary credentials from STS AssumeRole or SSO are automatically refreshed.
- A credentials object (any object with `access_key_id`, `secret_access_key`, and `session_token` methods).

Any `Aws::CredentialProvider` from the AWS SDK for Ruby works out of the box (`Aws::SharedCredentials`, `Aws::AssumeRoleCredentials`, `Aws::InstanceProfileCredentials`, etc.).

#### Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `region` | *(required)* | AWS region |
| `credentials` | *(required)* | Credential provider or credentials object (see above) |
| `throughput_target_gbps` | 10.0 | Target aggregate throughput; CRT auto-tunes parallelism to match |
| `part_size` | nil | Chunk size in bytes for parallel transfers (auto-tuned by CRT if nil) |
| `multipart_upload_threshold` | nil | Minimum body size before CRT uses multipart upload |
| `memory_limit_in_bytes` | nil | Cap on memory used for buffering transfer data |
| `max_active_connections_override` | nil | Cap on concurrent connections to S3 |

#### Downloading objects

```ruby
# Buffered — entire body returned in memory
resp = client.get_object(bucket: "my-bucket", key: "my-key")
puts resp.status_code  # => 200
puts resp.body         # => "file contents..."

# Download to file path — CRT writes directly to disk (fastest path)
resp = client.get_object(bucket: "my-bucket", key: "large-file.bin",
                         response_target: "/tmp/large-file.bin")
# resp.body is nil; data went straight to the file

# Download to File object — also uses CRT direct file I/O
File.open("/tmp/large-file.bin", "wb") do |f|
  resp = client.get_object(bucket: "my-bucket", key: "large-file.bin",
                           response_target: f)
end
# File objects are automatically converted to their path, so this is
# just as fast as passing the path string directly.

# Stream to an IO object
io = StringIO.new
resp = client.get_object(bucket: "my-bucket", key: "my-key",
                         response_target: io)
io.rewind
puts io.read

# Block streaming — process chunks as they arrive
client.get_object(bucket: "my-bucket", key: "my-key") do |chunk|
  # process each chunk
end
```

#### Uploading objects

```ruby
# String body
client.put_object(bucket: "my-bucket", key: "my-key", body: "hello world")

# File body — CRT reads directly from disk (fastest path)
File.open("large-file.bin", "rb") do |f|
  client.put_object(bucket: "my-bucket", key: "large-file.bin", body: f)
end

# IO body (e.g. StringIO)
io = StringIO.new("data from IO")
client.put_object(bucket: "my-bucket", key: "my-key", body: io)

# With explicit content type and length
client.put_object(
  bucket: "my-bucket",
  key: "my-key",
  body: "hello",
  content_type: "text/plain",
  content_length: 5
)
```

#### Checksum support

```ruby
# Compute and attach a checksum on upload
client.put_object(
  bucket: "my-bucket",
  key: "my-key",
  body: "hello",
  checksum_algorithm: "CRC32"  # CRC32, CRC32C, SHA1, or SHA256
)

# Validate checksum on download
resp = client.get_object(
  bucket: "my-bucket",
  key: "my-key",
  checksum_mode: "ENABLED"
)
puts resp.checksum_validated  # => "CRC32" (or nil if no checksum was present)
```

#### Progress reporting

```ruby
on_progress = ->(bytes_transferred) { puts "#{bytes_transferred} bytes" }

client.get_object(bucket: "my-bucket", key: "large.bin",
                  response_target: "/tmp/large.bin",
                  on_progress: on_progress)

client.put_object(bucket: "my-bucket", key: "large.bin",
                  body: File.open("large.bin", "rb"),
                  on_progress: on_progress)
```

#### Response object

Both `get_object` and `put_object` return an `AwsCrt::S3::Response`:

| Attribute | Type | Description |
|-----------|------|-------------|
| `status_code` | Integer | HTTP status code |
| `headers` | Hash | Response headers (String keys and values) |
| `body` | String or nil | Response body (nil when streamed to a target) |
| `checksum_validated` | String or nil | Checksum algorithm validated by the CRT |
| `successful?` | Boolean | True if status code is 2xx |

#### Error handling

```ruby
begin
  client.get_object(bucket: "my-bucket", key: "nonexistent")
rescue AwsCrt::S3::ServiceError => e
  # HTTP error from S3 (4xx/5xx)
  puts e.message      # => "S3 service error: HTTP 404"
  puts e.status_code   # => 404
  puts e.headers       # => { "x-amz-request-id" => "..." }
  puts e.error_body    # => "<Error><Code>NoSuchKey</Code>..."
rescue AwsCrt::S3::NetworkError => e
  # Connection/transport failure
  puts e.message
rescue AwsCrt::S3::Error => e
  # Catch-all for any S3 error
  puts e.message
end
```

Error hierarchy:

```
AwsCrt::Error
  └── AwsCrt::S3::Error
        ├── AwsCrt::S3::ServiceError   (HTTP 4xx/5xx from S3)
        └── AwsCrt::S3::NetworkError   (connection/transport failures)
```

#### CRT S3 client vs HTTP client plugin

The gem offers two ways to talk to S3:

| | CRT S3 Client (`AwsCrt::S3::Client`) | CRT HTTP Plugin (`AwsCrt::Http::Plugin`) |
|---|---|---|
| Interface | Standalone client with `get_object`/`put_object` | Drop-in replacement for `Net::HTTP` in the SDK |
| Request splitting | Automatic parallel multipart | None (single HTTP request) |
| Per-chunk retries | Yes | No (full-request retry only) |
| File I/O | Direct CRT file I/O (bypasses Ruby) | Streams through Ruby |
| Best for | Large object transfers (multi-MB+) | General AWS API calls, small S3 operations |

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

The AWS CRT libraries are licensed under [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0).

## Code of Conduct

Everyone interacting in this project's codebases, issue trackers, chat rooms,
and mailing lists is expected to follow the
[code of conduct](CODE_OF_CONDUCT.md).
