//! Ruby-facing `AwsCrt::Http::Client` class.
//!
//! A single `HttpClient` instance owns a thread-safe map of connection
//! managers keyed by endpoint. The Ruby side never sees connection pools —
//! it just calls `client.request(endpoint, method, path, headers, body)`.
//!
//! The client is designed to be frozen and shared across Ruby 4 Ractors.
//! All mutable state lives behind Rust's `Mutex`, invisible to Ruby's
//! Ractor isolation checks.

use std::collections::HashMap;
use std::sync::Mutex;

use magnus::prelude::*;
use magnus::rb_sys::AsRawValue;
use magnus::scan_args::scan_args;
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::value::Lazy;
use magnus::{data_type_builder, method, Error, RArray, RClass, RHash, RString, Ruby, Symbol, Value};
use rb_sys::VALUE;

use crate::connection_manager::{ConnectionManager, ConnectionManagerOptions};
use crate::http;
use crate::proxy::{ProxyAuthType, ProxyOptions};
use crate::tls::TlsOptions;

// ---------------------------------------------------------------------------
// HttpClient — the Ractor-shareable HTTP client
// ---------------------------------------------------------------------------

/// Configuration captured at construction time. Immutable after init.
struct ClientConfig {
    max_connections: usize,
    max_connection_idle_ms: u64,
    connect_timeout_ms: u32,
    read_timeout_ms: u64,
    ssl_verify_peer: bool,
    ssl_ca_bundle: Option<String>,
    proxy: Option<ProxyOptions>,
}

/// Ruby class `AwsCrt::Http::Client`.
///
/// Owns a map of CRT connection managers keyed by endpoint string.
/// Thread-safe: the map is protected by a Rust Mutex, and the CRT
/// handles internal synchronization for each connection manager.
///
/// Marked `frozen_shareable` so it can be frozen and shared across
/// Ruby 4 Ractors.
pub struct HttpClient {
    config: ClientConfig,
    pools: Mutex<HashMap<String, ConnectionManager>>,
}

// SAFETY: All mutable state is behind Mutex. CRT connection managers
// are internally thread-safe. No Ruby VALUEs are stored.
unsafe impl Send for HttpClient {}
unsafe impl Sync for HttpClient {}

impl DataTypeFunctions for HttpClient {}

unsafe impl TypedData for HttpClient {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get::<_, magnus::RModule>("Http")
                .unwrap()
                .const_get("Client")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        static DATA_TYPE: DataType = data_type_builder!(HttpClient, "AwsCrt::Http::Client")
            .free_immediately()
            .frozen_shareable()
            .build();
        &DATA_TYPE
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl HttpClient {
    /// Ruby: `Client.new(options = {})`
    ///
    /// options:
    ///   :max_connections      - Integer (default 25)
    ///   :max_connection_idle_ms - Integer (default 60_000)
    ///   :connect_timeout_ms   - Integer (default 60_000)
    ///   :read_timeout_ms      - Integer (default 0, meaning no timeout)
    ///   :ssl_verify_peer      - Boolean (default true)
    ///   :ssl_ca_bundle        - String path (default nil)
    ///   :proxy                - Hash with :host, :port, :username, :password (default nil)
    fn rb_new(args: &[Value]) -> Result<typed_data::Obj<Self>, Error> {
        let args = scan_args::<(), (Option<RHash>,), (), (), (), ()>(args)?;
        let opts = args.optional.0.unwrap_or_else(RHash::new);

        let max_connections = hash_get_usize(&opts, "max_connections", 25)?;
        let max_connection_idle_ms = hash_get_u64(&opts, "max_connection_idle_ms", 60_000)?;
        let connect_timeout_ms = hash_get_u32(&opts, "connect_timeout_ms", 60_000)?;
        let read_timeout_ms = hash_get_u64(&opts, "read_timeout_ms", 0)?;
        let ssl_verify_peer = hash_get_bool(&opts, "ssl_verify_peer", true)?;
        let ssl_ca_bundle = hash_get_string(&opts, "ssl_ca_bundle")?;
        let proxy = parse_proxy_options(&opts)?;

        let client = HttpClient {
            config: ClientConfig {
                max_connections,
                max_connection_idle_ms,
                connect_timeout_ms,
                read_timeout_ms,
                ssl_verify_peer,
                ssl_ca_bundle,
                proxy,
            },
            pools: Mutex::new(HashMap::new()),
        };

        Ok(typed_data::Obj::wrap(client))
    }

    /// Ruby: `client.request(endpoint, method, path, headers, body = nil, &block)`
    ///
    /// Buffered: returns [status_code, headers_array, body_string]
    /// Streaming (block given): returns [status_code, headers_array]
    fn rb_request(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<Value, Error> {
        let args = scan_args::<(String, String, String, RArray), (Option<RString>,), (), (), (), ()>(args)?;
        let endpoint = args.required.0;
        let method = args.required.1;
        let path = args.required.2;
        let headers = args.required.3;
        let body = args.optional.0;

        // Get or create connection manager for this endpoint
        let cm_ptr = rb_self.get_or_create_pool(&endpoint)?;
        let read_timeout_ms = rb_self.config.read_timeout_ms;

        // Convert Ruby headers array [[name, value], ...] to Vec<(String, String)>
        let header_len = headers.len();
        let mut header_vec: Vec<(String, String)> = Vec::with_capacity(header_len);
        unsafe {
            let arr_ptr = rb_sys::RARRAY_CONST_PTR(headers.as_raw());
            for i in 0..header_len {
                let pair_val: VALUE = *arr_ptr.add(i);
                let pair_ptr = rb_sys::RARRAY_CONST_PTR(pair_val);
                let name_val: VALUE = *pair_ptr;
                let value_val: VALUE = *pair_ptr.add(1);

                let name_ptr = rb_sys::RSTRING_PTR(name_val) as *const u8;
                let name_len = rb_sys::RSTRING_LEN(name_val) as usize;
                let name = std::str::from_utf8_unchecked(
                    std::slice::from_raw_parts(name_ptr, name_len),
                ).to_string();

                let value_ptr = rb_sys::RSTRING_PTR(value_val) as *const u8;
                let value_len = rb_sys::RSTRING_LEN(value_val) as usize;
                let value = std::str::from_utf8_unchecked(
                    std::slice::from_raw_parts(value_ptr, value_len),
                ).to_string();

                header_vec.push((name, value));
            }
        }

        // Get body bytes (copy into Rust before releasing GVL)
        let body_bytes: Option<Vec<u8>> = match body {
            Some(s) if !s.is_nil() => {
                let slice = unsafe { s.as_slice() };
                Some(slice.to_vec())
            }
            _ => None,
        };

        // Check if a block was given
        let block = ruby.block_given();

        if block {
            let block_proc = ruby.block_proc()?;

            let mut captured_status: i32 = 0;
            let mut captured_headers: Vec<(String, String)> = Vec::new();

            http::make_streaming_request(
                cm_ptr,
                &method,
                &path,
                &header_vec,
                body_bytes,
                read_timeout_ms,
                |status, hdrs| {
                    captured_status = status;
                    captured_headers = hdrs.to_vec();
                },
                |chunk| {
                    let rb_chunk = ruby.str_from_slice(chunk);
                    let _ = block_proc.call::<_, Value>((rb_chunk,));
                },
            )
            .map_err(|e| -> Error { e.into() })?;

            let rb_headers = build_ruby_headers(ruby, &captured_headers);
            let arr = RArray::from_slice(&[
                ruby.into_value(captured_status),
                rb_headers.as_value(),
            ]);
            Ok(arr.as_value())
        } else {
            let response = http::make_request(
                cm_ptr,
                &method,
                &path,
                &header_vec,
                body_bytes,
                read_timeout_ms,
            )
            .map_err(|e| -> Error { e.into() })?;

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

impl HttpClient {
    /// Get or create a ConnectionManager for the given endpoint.
    /// The pool map is protected by a Rust Mutex.
    fn get_or_create_pool(
        &self,
        endpoint: &str,
    ) -> Result<*mut crate::connection_manager::AwsHttpConnectionManager, Error> {
        let mut pools = self.pools.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "HttpClient pool lock poisoned",
            )
        })?;

        if let Some(cm) = pools.get(endpoint) {
            return Ok(cm.as_ptr());
        }

        // Parse endpoint and create a new connection manager
        let (scheme, host, port) = parse_endpoint(endpoint)?;
        let use_tls = scheme == "https";

        let tls_options = if use_tls {
            Some(TlsOptions {
                verify_peer: self.config.ssl_verify_peer,
                ca_filepath: self.config.ssl_ca_bundle.clone(),
                alpn_list: None,
            })
        } else {
            None
        };

        let cm_opts = ConnectionManagerOptions {
            host,
            port,
            max_connections: self.config.max_connections,
            max_connection_idle_ms: self.config.max_connection_idle_ms,
            connect_timeout_ms: self.config.connect_timeout_ms,
            tls_options,
            proxy_options: self.config.proxy.clone(),
        };

        let cm = ConnectionManager::new(&cm_opts)
            .map_err(|e| -> Error { e.into() })?;
        let ptr = cm.as_ptr();
        pools.insert(endpoint.to_string(), cm);
        Ok(ptr)
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Parse an endpoint string like "https://example.com:443" into (scheme, host, port).
fn parse_endpoint(endpoint: &str) -> Result<(String, String, u32), Error> {
    let (scheme, rest) = endpoint
        .split_once("://")
        .ok_or_else(|| {
            Error::new(
                magnus::exception::arg_error(),
                format!("Invalid endpoint '{}': expected scheme://host[:port]", endpoint),
            )
        })?;

    let scheme = scheme.to_lowercase();
    if scheme != "http" && scheme != "https" {
        return Err(Error::new(
            magnus::exception::arg_error(),
            format!("Unsupported scheme '{}': expected http or https", scheme),
        ));
    }

    let (host, port) = if let Some((h, p)) = rest.rsplit_once(':') {
        let port: u32 = p.parse().map_err(|_| {
            Error::new(
                magnus::exception::arg_error(),
                format!("Invalid port in endpoint '{}'", endpoint),
            )
        })?;
        (h.to_string(), port)
    } else {
        let default_port = if scheme == "https" { 443 } else { 80 };
        (rest.to_string(), default_port)
    };

    let host = host.trim_end_matches('/').to_string();

    if host.is_empty() {
        return Err(Error::new(
            magnus::exception::arg_error(),
            format!("Empty host in endpoint '{}'", endpoint),
        ));
    }

    Ok((scheme, host, port))
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

fn hash_get_u32(hash: &RHash, key: &str, default: u32) -> Result<u32, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => Ok(magnus::TryConvert::try_convert(v)?),
        None => Ok(default),
    }
}

fn hash_get_u64(hash: &RHash, key: &str, default: u64) -> Result<u64, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => Ok(magnus::TryConvert::try_convert(v)?),
        None => Ok(default),
    }
}

fn hash_get_usize(hash: &RHash, key: &str, default: usize) -> Result<usize, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => Ok(magnus::TryConvert::try_convert(v)?),
        None => Ok(default),
    }
}

fn hash_get_bool(hash: &RHash, key: &str, default: bool) -> Result<bool, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => Ok(magnus::TryConvert::try_convert(v)?),
        None => Ok(default),
    }
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
                    Error::new(magnus::exception::arg_error(), "proxy :host is required")
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

/// Convert response headers to a Ruby Array of [name, value] pairs.
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

/// Register the `AwsCrt::Http::Client` class with magnus.
pub fn define_http_client(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let class = http_module.define_class("Client", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", magnus::function!(HttpClient::rb_new, -1))?;
    class.define_method("request", method!(HttpClient::rb_request, -1))?;

    Ok(())
}
