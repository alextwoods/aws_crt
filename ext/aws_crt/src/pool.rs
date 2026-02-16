//! Ruby-facing `AwsCrt::Http::ConnectionPool` class.
//!
//! Wraps the Rust `ConnectionManager` and `http::make_request` /
//! `http::make_streaming_request` functions, exposing them to Ruby via magnus.

use std::cell::RefCell;

use magnus::prelude::*;
use magnus::scan_args::scan_args;
use magnus::typed_data;
use magnus::{method, Error, RArray, RHash, RString, Ruby, Symbol, Value};

use crate::connection_manager::{ConnectionManager, ConnectionManagerOptions};
use crate::http;
use crate::proxy::{ProxyAuthType, ProxyOptions};
use crate::tls::TlsOptions;

/// Ruby class `AwsCrt::Http::ConnectionPool`.
///
/// Each instance owns a CRT connection manager bound to a single endpoint.
/// Thread-safe: the CRT handles internal synchronization for connection
/// acquisition and release.
#[magnus::wrap(class = "AwsCrt::Http::ConnectionPool", free_immediately, size)]
pub struct ConnectionPool {
    inner: RefCell<Option<ConnectionManager>>,
    read_timeout_ms: RefCell<u64>,
}

impl Default for ConnectionPool {
    fn default() -> Self {
        Self {
            inner: RefCell::new(None),
            read_timeout_ms: RefCell::new(0),
        }
    }
}

/// Extract a String option from a Ruby Hash by symbol key.
fn hash_get_string(hash: &RHash, key: &str) -> Result<Option<String>, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(None),
        Some(v) => {
            let s: String = magnus::TryConvert::try_convert(v)?;
            Ok(Some(s))
        }
        None => Ok(None),
    }
}

/// Extract a u32 option from a Ruby Hash by symbol key.
fn hash_get_u32(hash: &RHash, key: &str, default: u32) -> Result<u32, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: u32 = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract a u64 option from a Ruby Hash by symbol key.
fn hash_get_u64(hash: &RHash, key: &str, default: u64) -> Result<u64, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: u64 = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract a usize option from a Ruby Hash by symbol key.
fn hash_get_usize(hash: &RHash, key: &str, default: usize) -> Result<usize, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: usize = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract a bool option from a Ruby Hash by symbol key.
fn hash_get_bool(hash: &RHash, key: &str, default: bool) -> Result<bool, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let b: bool = magnus::TryConvert::try_convert(v)?;
            Ok(b)
        }
        None => Ok(default),
    }
}

impl ConnectionPool {
    /// Ruby: `ConnectionPool.new(endpoint, options = {})`
    ///
    /// endpoint: String like "https://example.com:443" or "http://localhost:8080"
    /// options:
    ///   :max_connections      - Integer (default 25)
    ///   :max_connection_idle_ms - Integer (default 60_000)
    ///   :connect_timeout_ms   - Integer (default 60_000)
    ///   :read_timeout_ms      - Integer (default 0, meaning no timeout)
    ///   :ssl_verify_peer      - Boolean (default true)
    ///   :ssl_ca_bundle        - String path (default nil)
    ///   :proxy                - Hash with :host, :port, :username, :password (default nil)
    fn rb_initialize(rb_self: &Self, args: &[Value]) -> Result<(), Error> {
        let args = scan_args::<(String,), (Option<RHash>,), (), (), (), ()>(args)?;
        let endpoint = args.required.0;
        let options = args.optional.0;

        // Parse endpoint: "scheme://host:port"
        let (scheme, host, port) = parse_endpoint(&endpoint)?;
        let use_tls = scheme == "https";

        // Extract options from the Ruby hash (or use defaults)
        let opts = options.unwrap_or_else(RHash::new);

        let max_connections = hash_get_usize(&opts, "max_connections", 25)?;
        let max_connection_idle_ms =
            hash_get_u64(&opts, "max_connection_idle_ms", 60_000)?;
        let connect_timeout_ms =
            hash_get_u32(&opts, "connect_timeout_ms", 60_000)?;
        let read_timeout_ms =
            hash_get_u64(&opts, "read_timeout_ms", 0)?;
        let ssl_verify_peer =
            hash_get_bool(&opts, "ssl_verify_peer", true)?;
        let ssl_ca_bundle =
            hash_get_string(&opts, "ssl_ca_bundle")?;

        // TLS options (only for HTTPS)
        let tls_options = if use_tls {
            Some(TlsOptions {
                verify_peer: ssl_verify_peer,
                ca_filepath: ssl_ca_bundle,
                alpn_list: None,
            })
        } else {
            None
        };

        // Proxy options
        let proxy_options = parse_proxy_options(&opts)?;

        let cm_opts = ConnectionManagerOptions {
            host,
            port,
            max_connections,
            max_connection_idle_ms,
            connect_timeout_ms,
            tls_options,
            proxy_options,
        };

        let cm = ConnectionManager::new(&cm_opts)
            .map_err(|e| -> Error { e.into() })?;

        *rb_self.inner.borrow_mut() = Some(cm);
        *rb_self.read_timeout_ms.borrow_mut() = read_timeout_ms;

        Ok(())
    }

    /// Ruby: `pool.request(method, path, headers, body = nil, &block)`
    ///
    /// Returns an Array: [status_code, headers_array, body_string]
    /// If a block is given, streams the body and returns [status_code, headers_array]
    fn rb_request(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<Value, Error> {
        let args = scan_args::<(String, String, RArray), (Option<RString>,), (), (), (), ()>(args)?;
        let method = args.required.0;
        let path = args.required.1;
        let headers = args.required.2;
        let body = args.optional.0;
        let inner = rb_self.inner.borrow();
        let cm = inner.as_ref().ok_or_else(|| {
            Error::new(
                ruby.exception_runtime_error(),
                "ConnectionPool not initialized",
            )
        })?;

        let read_timeout_ms = *rb_self.read_timeout_ms.borrow();

        // Convert Ruby headers array [[name, value], ...] to Vec<(String, String)>
        let mut header_vec: Vec<(String, String)> = Vec::new();
        let header_len = headers.len();
        for i in 0..header_len {
            let pair: RArray = headers.entry(i as isize)?;
            let name: String = pair.entry(0)?;
            let value: String = pair.entry(1)?;
            header_vec.push((name, value));
        }

        // Get body bytes (copy into Rust before releasing GVL)
        let body_bytes: Option<Vec<u8>> = match body {
            Some(s) if !s.is_nil() => {
                let slice = unsafe { s.as_slice() };
                Some(slice.to_vec())
            }
            _ => None,
        };
        let body_ref = body_bytes.as_deref();

        // Check if a block was given
        let block = ruby.block_given();

        if block {
            // Streaming mode — yield chunks to the Ruby block.
            // Headers and status are captured via the on_headers callback
            // before any body chunks are yielded.
            let block_proc = ruby.block_proc()?;

            let mut captured_status: i32 = 0;
            let mut captured_headers: Vec<(String, String)> = Vec::new();

            http::make_streaming_request(
                cm.as_ptr(),
                &method,
                &path,
                &header_vec,
                body_ref,
                read_timeout_ms,
                |status, hdrs| {
                    captured_status = status;
                    captured_headers = hdrs.to_vec();
                },
                |chunk| {
                    // Yield chunk to the Ruby block (GVL is held here)
                    let rb_chunk = ruby.str_from_slice(chunk);
                    let _ = block_proc.call::<_, Value>((rb_chunk,));
                },
            )
            .map_err(|e| -> Error { e.into() })?;

            // Build return value: [status_code, headers_array]
            let rb_headers = build_ruby_headers(ruby, &captured_headers);
            let arr = RArray::from_slice(&[
                ruby.into_value(captured_status),
                rb_headers.as_value(),
            ]);
            Ok(arr.as_value())
        } else {
            // Buffered mode — return complete response
            let response = http::make_request(
                cm.as_ptr(),
                &method,
                &path,
                &header_vec,
                body_ref,
                read_timeout_ms,
            )
            .map_err(|e| -> Error { e.into() })?;

            // Build return value: [status_code, headers_array, body_string]
            let rb_headers = build_ruby_headers(ruby, &response.headers);
            let rb_body = ruby.str_from_slice(&response.body);
            let arr = RArray::from_slice(&[
                ruby.into_value(response.status_code),
                rb_headers.as_value(),
                rb_body.as_value(),
            ]);
            Ok(arr.as_value())
        }
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Parse an endpoint string like "https://example.com:443" into (scheme, host, port).
fn parse_endpoint(endpoint: &str) -> Result<(String, String, u32), Error> {
    // Split scheme
    let (scheme, rest) = endpoint
        .split_once("://")
        .ok_or_else(|| {
            Error::new(
                magnus::exception::arg_error(),
                format!(
                    "Invalid endpoint '{}': expected scheme://host[:port]",
                    endpoint
                ),
            )
        })?;

    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return Err(Error::new(
            magnus::exception::arg_error(),
            format!("Unsupported scheme '{}': expected http or https", scheme),
        ));
    }

    // Split host and port
    let (host, port) = if let Some((h, p)) = rest.rsplit_once(':') {
        // Check if this is an IPv6 address like [::1]:8080
        // or just host:port
        let port: u32 = p.parse().map_err(|_| {
            Error::new(
                magnus::exception::arg_error(),
                format!("Invalid port in endpoint '{}'", endpoint),
            )
        })?;
        (h.to_string(), port)
    } else {
        // No port specified — use default for scheme
        let default_port = if scheme == "https" { 443 } else { 80 };
        (rest.to_string(), default_port)
    };

    // Strip trailing slash from host
    let host = host.trim_end_matches('/').to_string();

    if host.is_empty() {
        return Err(Error::new(
            magnus::exception::arg_error(),
            format!("Empty host in endpoint '{}'", endpoint),
        ));
    }

    Ok((scheme, host, port))
}

/// Parse proxy options from a Ruby Hash's :proxy key.
fn parse_proxy_options(opts: &RHash) -> Result<Option<ProxyOptions>, Error> {
    let sym = Symbol::new("proxy");
    let val: Option<Value> = opts.lookup(sym)?;
    match val {
        Some(v) if !v.is_nil() => {
            let proxy_hash = RHash::from_value(v).ok_or_else(|| {
                Error::new(
                    magnus::exception::type_error(),
                    ":proxy must be a Hash with :host, :port keys",
                )
            })?;

            let host = hash_get_string(&proxy_hash, "host")?
                .ok_or_else(|| {
                    Error::new(
                        magnus::exception::arg_error(),
                        "proxy :host is required",
                    )
                })?;
            let port = hash_get_u32(&proxy_hash, "port", 8080)?;
            let username = hash_get_string(&proxy_hash, "username")?;
            let password = hash_get_string(&proxy_hash, "password")?;

            let auth_type = if username.is_some() {
                ProxyAuthType::Basic
            } else {
                ProxyAuthType::None
            };

            Ok(Some(ProxyOptions {
                host,
                port,
                auth_type,
                auth_username: username,
                auth_password: password,
            }))
        }
        _ => Ok(None),
    }
}

/// Convert response headers Vec<(String, String)> to a Ruby Array of [name, value] pairs.
fn build_ruby_headers(ruby: &Ruby, headers: &[(String, String)]) -> RArray {
    let arr = RArray::with_capacity(headers.len());
    for (name, value) in headers {
        let pair = RArray::from_slice(&[
            ruby.str_new(name).as_value(),
            ruby.str_new(value).as_value(),
        ]);
        let _ = arr.push(pair);
    }
    arr
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register the `AwsCrt::Http::ConnectionPool` class with magnus.
pub fn define_connection_pool(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let class =
        http_module.define_class("ConnectionPool", ruby.class_object())?;
    class.define_alloc_func::<ConnectionPool>();
    class.define_method(
        "initialize",
        method!(ConnectionPool::rb_initialize, -1),
    )?;
    class.define_method("request", method!(ConnectionPool::rb_request, -1))?;

    Ok(())
}
