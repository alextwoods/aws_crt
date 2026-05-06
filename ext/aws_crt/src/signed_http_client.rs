//! Combined SigV4 signer + HTTP client.
//!
//! `AwsCrt::SignedHttpClient` signs and sends HTTP requests in a single
//! native call, avoiding the overhead of crossing the Ruby/Rust boundary
//! twice. The CRT HTTP message is built once, signed in-place, and sent
//! directly — no intermediate conversion back to Ruby types between
//! signing and sending.
//!
//! Performance advantages over separate signer + client:
//! - One Ruby→Rust transition instead of two
//! - No re-serialization of headers/body between sign and send
//! - The signed CRT message is reused directly for the HTTP request
//! - Single GVL release covers both signing wait and HTTP wait
//!
//! The client is Ractor-shareable (frozen_shareable) and manages
//! connection pools internally, just like `HttpClient`.

use std::collections::HashMap;
use std::sync::Mutex;

use magnus::prelude::*;
use magnus::rb_sys::{AsRawValue, FromRawValue};
use magnus::scan_args::{get_kwargs, scan_args};
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::value::Lazy;
use magnus::{data_type_builder, method, Error, RArray, RClass, RHash, RString, Ruby, Symbol, Value};
use rb_sys::VALUE;

use crate::connection_manager::{ConnectionManager, ConnectionManagerOptions};
use crate::credentials::CredentialsProvider;
use crate::error::CrtError;
use crate::http::{
    self, AwsByteCursor, AwsHttpHeader, AwsInputStream,
    aws_default_allocator, aws_http_message_add_header, aws_http_message_new_request,
    aws_http_message_release, aws_http_message_set_body_stream,
    aws_http_message_set_request_method, aws_http_message_set_request_path,
    aws_input_stream_new_from_cursor, aws_input_stream_release,
};
use crate::http_client::compute_checksum;
use crate::proxy::{ProxyAuthType, ProxyOptions};
use crate::sharable_string_io::SharableStringIO;
use crate::sigv4_signer::sign_crt_message;
use crate::tls::TlsOptions;

// ---------------------------------------------------------------------------
// SignedHttpClient — combined signer + HTTP client
// ---------------------------------------------------------------------------

/// Signing configuration captured at construction time. Immutable after init.
struct SignerConfig {
    service: String,
    apply_sha256_header: bool,
    use_double_uri_encode: bool,
    normalize_uri_path: bool,
    sign_body: bool,
}

/// HTTP client configuration captured at construction time. Immutable after init.
struct ClientConfig {
    max_connections: usize,
    max_connection_idle_ms: u64,
    connect_timeout_ms: u32,
    read_timeout_ms: u64,
    ssl_verify_peer: bool,
    ssl_ca_bundle: Option<String>,
    proxy: Option<ProxyOptions>,
}

/// Ruby class `AwsCrt::SignedHttpClient`.
///
/// Combines SigV4 signing and HTTP request sending into a single native
/// operation. Owns a map of CRT connection managers keyed by endpoint
/// (same pattern as `HttpClient`) and a signing configuration.
///
/// Marked `frozen_shareable` so it can be frozen and shared across
/// Ruby 4 Ractors.
pub struct SignedHttpClient {
    signer_config: SignerConfig,
    client_config: ClientConfig,
    pools: Mutex<HashMap<String, ConnectionManager>>,
}

// SAFETY: All mutable state is behind Mutex. CRT connection managers
// are internally thread-safe. No Ruby VALUEs are stored.
unsafe impl Send for SignedHttpClient {}
unsafe impl Sync for SignedHttpClient {}

impl DataTypeFunctions for SignedHttpClient {}

unsafe impl TypedData for SignedHttpClient {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get("SignedHttpClient")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        static DATA_TYPE: DataType =
            data_type_builder!(SignedHttpClient, "AwsCrt::SignedHttpClient")
                .free_immediately()
                .frozen_shareable()
                .build();
        &DATA_TYPE
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl SignedHttpClient {
    /// Ruby: `SignedHttpClient.new(options = {})`
    ///
    /// Signing options:
    ///   :service (required) — AWS service name
    ///   :apply_sha256_header (true) — add x-amz-content-sha256
    ///   :use_double_uri_encode (true) — double-encode URI
    ///   :normalize_uri_path (true) — normalize URI path
    ///   :sign_body (false) — compute SHA-256 of body
    ///
    /// HTTP client options:
    ///   :max_connections (25)
    ///   :max_connection_idle_ms (60_000)
    ///   :connect_timeout_ms (60_000)
    ///   :read_timeout_ms (0)
    ///   :ssl_verify_peer (true)
    ///   :ssl_ca_bundle (nil)
    ///   :proxy (nil)
    fn rb_new(args: &[Value]) -> Result<typed_data::Obj<Self>, Error> {
        let args = scan_args::<(), (Option<RHash>,), (), (), (), ()>(args)?;
        let opts = args.optional.0.unwrap_or_else(RHash::new);

        // Signing config
        let service = hash_get_string_required(&opts, "service")?;
        let apply_sha256_header = hash_get_bool(&opts, "apply_sha256_header", true)?;
        let use_double_uri_encode = hash_get_bool(&opts, "use_double_uri_encode", true)?;
        let normalize_uri_path = hash_get_bool(&opts, "normalize_uri_path", true)?;
        let sign_body = hash_get_bool(&opts, "sign_body", false)?;

        // HTTP client config
        let max_connections = hash_get_usize(&opts, "max_connections", 25)?;
        let max_connection_idle_ms = hash_get_u64(&opts, "max_connection_idle_ms", 60_000)?;
        let connect_timeout_ms = hash_get_u32(&opts, "connect_timeout_ms", 60_000)?;
        let read_timeout_ms = hash_get_u64(&opts, "read_timeout_ms", 0)?;
        let ssl_verify_peer = hash_get_bool(&opts, "ssl_verify_peer", true)?;
        let ssl_ca_bundle = hash_get_string(&opts, "ssl_ca_bundle")?;
        let proxy = parse_proxy_options(&opts)?;

        let client = SignedHttpClient {
            signer_config: SignerConfig {
                service,
                apply_sha256_header,
                use_double_uri_encode,
                normalize_uri_path,
                sign_body,
            },
            client_config: ClientConfig {
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

    /// Ruby: `client.request(endpoint, method, path, headers, body = nil,
    ///          region:, access_key_id:, secret_access_key:, session_token: nil,
    ///          streaming_io: false, on_data: nil, on_headers: nil,
    ///          checksum_algorithms: nil, &block)`
    ///
    /// Always returns an `AwsCrt::Http::Response` instance.
    fn rb_request(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<Value, Error> {
        // Parse: endpoint, method, path, headers (required), body (optional), + kwargs
        let args = scan_args::<(String, String, String, RArray), (Option<Value>,), (), (), RHash, ()>(args)?;
        let endpoint = args.required.0;
        let method = args.required.1;
        let path = args.required.2;
        let headers_arr = args.required.3;
        let body_val = args.optional.0;

        // Extract keyword arguments
        let kwargs = get_kwargs::<_, (String, String, String), (Option<String>, Option<bool>, Option<Value>, Option<Value>, Option<Value>), ()>(
            args.keywords,
            &["region", "access_key_id", "secret_access_key"],
            &["session_token", "streaming_io", "on_data", "on_headers", "checksum_algorithms"],
        )?;
        let (region, access_key_id, secret_access_key) = kwargs.required;
        let (session_token, streaming_io_opt, on_data_opt, on_headers_opt, checksum_algorithms_opt) = kwargs.optional;
        let streaming_io = streaming_io_opt.unwrap_or(false);

        // Extract on_data listeners (Array of Procs or nil)
        let on_data_listeners: Option<RArray> = match on_data_opt {
            Some(v) if !v.is_nil() => {
                let arr = RArray::from_value(v).ok_or_else(|| {
                    Error::new(
                        magnus::exception::type_error(),
                        "on_data must be an Array of callable objects",
                    )
                })?;
                if arr.len() > 0 { Some(arr) } else { None }
            }
            _ => None,
        };

        // Extract on_headers listeners (Array of Procs or nil)
        let on_headers_listeners: Option<RArray> = match on_headers_opt {
            Some(v) if !v.is_nil() => {
                let arr = RArray::from_value(v).ok_or_else(|| {
                    Error::new(
                        magnus::exception::type_error(),
                        "on_headers must be an Array of callable objects",
                    )
                })?;
                if arr.len() > 0 { Some(arr) } else { None }
            }
            _ => None,
        };

        // Extract checksum_algorithms (Array of Strings or nil)
        let checksum_algorithms: Option<Vec<String>> = match checksum_algorithms_opt {
            Some(v) if !v.is_nil() => {
                let arr = RArray::from_value(v).ok_or_else(|| {
                    Error::new(
                        magnus::exception::type_error(),
                        "checksum_algorithms must be an Array of Strings",
                    )
                })?;
                let len = arr.len();
                if len == 0 {
                    None
                } else {
                    let mut algs = Vec::with_capacity(len);
                    for i in 0..len {
                        let val: Value = unsafe {
                            Value::from_raw(*rb_sys::RARRAY_CONST_PTR(arr.as_raw()).add(i))
                        };
                        let s: String = magnus::TryConvert::try_convert(val)?;
                        algs.push(s);
                    }
                    Some(algs)
                }
            }
            _ => None,
        };

        // Check if a block was given
        let block = ruby.block_given();

        // Validate: streaming_io and block are mutually exclusive
        if streaming_io && block {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "streaming_io and block are mutually exclusive",
            ));
        }

        // Get or create connection manager
        let cm_ptr = rb_self.get_or_create_pool(&endpoint)?;
        let read_timeout_ms = rb_self.client_config.read_timeout_ms;

        // Convert Ruby headers array [[name, value], ...] to Vec<(String, String)>
        let header_len = headers_arr.len();
        let mut header_vec: Vec<(String, String)> = Vec::with_capacity(header_len);
        unsafe {
            let arr_ptr = rb_sys::RARRAY_CONST_PTR(headers_arr.as_raw());
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
        let body_bytes: Option<Vec<u8>> = match body_val {
            Some(v) if !v.is_nil() => {
                let s = RString::from_value(v).ok_or_else(|| {
                    Error::new(magnus::exception::type_error(), "body must be a String or nil")
                })?;
                let slice = unsafe { s.as_slice() };
                if slice.is_empty() { None } else { Some(slice.to_vec()) }
            }
            _ => None,
        };

        // --- Build CRT HTTP message ---
        let allocator = unsafe { aws_default_allocator() };
        let request = unsafe { aws_http_message_new_request(allocator) };
        if request.is_null() {
            return Err(CrtError::last_error().into());
        }

        // Set method and path
        unsafe {
            if aws_http_message_set_request_method(
                request,
                AwsByteCursor::from_slice(method.as_bytes()),
            ) != 0
            {
                aws_http_message_release(request);
                return Err(CrtError::last_error().into());
            }
            if aws_http_message_set_request_path(
                request,
                AwsByteCursor::from_slice(path.as_bytes()),
            ) != 0
            {
                aws_http_message_release(request);
                return Err(CrtError::last_error().into());
            }
        }

        // Add headers
        for (name, value) in &header_vec {
            let header = AwsHttpHeader {
                name: AwsByteCursor::from_slice(name.as_bytes()),
                value: AwsByteCursor::from_slice(value.as_bytes()),
                compression: 0,
                _pad: 0,
            };
            unsafe {
                if aws_http_message_add_header(request, header) != 0 {
                    aws_http_message_release(request);
                    return Err(CrtError::last_error().into());
                }
            }
        }

        // Set body stream if provided
        let mut body_stream: *mut AwsInputStream = std::ptr::null_mut();
        let body_data: Option<Vec<u8>>;
        if let Some(ref owned) = body_bytes {
            if !owned.is_empty() {
                let cursor = AwsByteCursor::from_slice(owned);
                body_stream = unsafe {
                    aws_input_stream_new_from_cursor(allocator, &cursor)
                };
                if body_stream.is_null() {
                    unsafe { aws_http_message_release(request) };
                    return Err(CrtError::last_error().into());
                }
                unsafe { aws_http_message_set_body_stream(request, body_stream) };
            }
        }
        body_data = body_bytes;

        // --- Sign the message in-place ---
        let creds_provider = CredentialsProvider::new_static(
            &access_key_id,
            &secret_access_key,
            session_token.as_deref(),
        )
        .map_err(|e| -> Error {
            // Clean up on credential error
            if !body_stream.is_null() {
                unsafe { aws_input_stream_release(body_stream) };
            }
            unsafe { aws_http_message_release(request) };
            e.into()
        })?;

        let sign_result = sign_crt_message(
            request,
            &region,
            &rb_self.signer_config.service,
            &creds_provider,
            rb_self.signer_config.apply_sha256_header,
            rb_self.signer_config.use_double_uri_encode,
            rb_self.signer_config.normalize_uri_path,
            rb_self.signer_config.sign_body,
        );

        if let Err(e) = sign_result {
            if !body_stream.is_null() {
                unsafe { aws_input_stream_release(body_stream) };
            }
            unsafe { aws_http_message_release(request) };
            return Err(e.into());
        }

        // --- Send the signed message directly ---
        if streaming_io {
            // streaming_io path: send buffered, wrap body in SharableStringIO
            let response = unsafe {
                http::send_pre_built_request(
                    cm_ptr,
                    request,
                    body_stream,
                    body_data,
                    read_timeout_ms,
                )
            }
            .map_err(|e| -> Error { e.into() })?;

            // Compute checksum over the body buffer
            let (checksum_algorithm, computed_checksum) =
                compute_checksum(&checksum_algorithms, &response.headers, &response.body);

            let rb_headers = build_ruby_headers(ruby, &response.headers);

            // Call on_headers listeners
            if let Some(ref listeners) = on_headers_listeners {
                let status_val = ruby.into_value(response.status_code);
                let rb_headers_value: Value = unsafe { Value::from_raw(rb_headers.as_raw()) };
                let len = listeners.len();
                for i in 0..len {
                    let listener: Value = unsafe {
                        Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                    };
                    let _: Value = listener.funcall("call", (status_val, rb_headers_value))?;
                }
            }

            // Notify on_data listeners with the complete body
            if let Some(ref listeners) = on_data_listeners {
                if !response.body.is_empty() {
                    let rb_chunk = ruby.str_from_slice(&response.body);
                    let len = listeners.len();
                    for i in 0..len {
                        let listener: Value = unsafe {
                            Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                        };
                        let _: Value = listener.funcall("call", (rb_chunk,))?;
                    }
                }
            }

            // Create a SharableStringIO with the response body (zero-copy move)
            let sio = SharableStringIO::new_with_buffer(response.body);

            let resp_obj = crate::http_response::HttpResponse::new_from_parts(
                response.status_code,
                rb_headers.as_raw(),
                sio.as_value().as_raw(),
                checksum_algorithm,
                computed_checksum,
            );
            Ok(resp_obj.as_value())
        } else if block {
            let block_proc = ruby.block_proc()?;

            let mut captured_status: i32 = 0;
            let mut captured_headers: Vec<(String, String)> = Vec::new();

            let send_result = unsafe {
                http::send_pre_built_streaming_request(
                    cm_ptr,
                    request,
                    body_stream,
                    body_data,
                    read_timeout_ms,
                    |status, hdrs| {
                        captured_status = status;
                        captured_headers = hdrs.to_vec();
                    },
                    |chunk| {
                        let rb_chunk = ruby.str_from_slice(chunk);
                        let _ = block_proc.call::<_, Value>((rb_chunk,));
                        // Notify on_data listeners for each chunk
                        if let Some(ref listeners) = on_data_listeners {
                            let len = listeners.len();
                            for i in 0..len {
                                let listener: Value = unsafe {
                                    Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                                };
                                let _ = listener.funcall::<_, _, Value>("call", (rb_chunk,));
                            }
                        }
                    },
                )
            };

            send_result.map_err(|e| -> Error { e.into() })?;

            let rb_headers = build_ruby_headers(ruby, &captured_headers);

            // Call on_headers listeners
            if let Some(ref listeners) = on_headers_listeners {
                let status_val = ruby.into_value(captured_status);
                let rb_headers_value: Value = unsafe { Value::from_raw(rb_headers.as_raw()) };
                let len = listeners.len();
                for i in 0..len {
                    let listener: Value = unsafe {
                        Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                    };
                    let _: Value = listener.funcall("call", (status_val, rb_headers_value))?;
                }
            }

            let resp_obj = crate::http_response::HttpResponse::new_from_parts(
                captured_status,
                rb_headers.as_raw(),
                ruby.qnil().as_value().as_raw(),
                None,
                None,
            );
            Ok(resp_obj.as_value())
        } else {
            // Buffered (default) path
            let response = unsafe {
                http::send_pre_built_request(
                    cm_ptr,
                    request,
                    body_stream,
                    body_data,
                    read_timeout_ms,
                )
            }
            .map_err(|e| -> Error { e.into() })?;

            // Compute checksum over the body buffer
            let (checksum_algorithm, computed_checksum) =
                compute_checksum(&checksum_algorithms, &response.headers, &response.body);

            let rb_headers = build_ruby_headers(ruby, &response.headers);

            // Call on_headers listeners
            if let Some(ref listeners) = on_headers_listeners {
                let status_val = ruby.into_value(response.status_code);
                let rb_headers_value: Value = unsafe { Value::from_raw(rb_headers.as_raw()) };
                let len = listeners.len();
                for i in 0..len {
                    let listener: Value = unsafe {
                        Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                    };
                    let _: Value = listener.funcall("call", (status_val, rb_headers_value))?;
                }
            }

            // Notify on_data listeners with the complete body
            if let Some(ref listeners) = on_data_listeners {
                if !response.body.is_empty() {
                    let rb_chunk = ruby.str_from_slice(&response.body);
                    let len = listeners.len();
                    for i in 0..len {
                        let listener: Value = unsafe {
                            Value::from_raw(*rb_sys::RARRAY_CONST_PTR(listeners.as_raw()).add(i))
                        };
                        let _: Value = listener.funcall("call", (rb_chunk,))?;
                    }
                }
            }

            let rb_body = ruby.str_from_slice(&response.body);
            let resp_obj = crate::http_response::HttpResponse::new_from_parts(
                response.status_code,
                rb_headers.as_raw(),
                rb_body.as_value().as_raw(),
                checksum_algorithm,
                computed_checksum,
            );
            Ok(resp_obj.as_value())
        }
    }
}

impl SignedHttpClient {
    /// Get or create a ConnectionManager for the given endpoint.
    fn get_or_create_pool(
        &self,
        endpoint: &str,
    ) -> Result<*mut crate::connection_manager::AwsHttpConnectionManager, Error> {
        let mut pools = self.pools.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SignedHttpClient pool lock poisoned",
            )
        })?;

        if let Some(cm) = pools.get(endpoint) {
            return Ok(cm.as_ptr());
        }

        let (scheme, host, port) = parse_endpoint(endpoint)?;
        let use_tls = scheme == "https";

        let tls_options = if use_tls {
            Some(TlsOptions {
                verify_peer: self.client_config.ssl_verify_peer,
                ca_filepath: self.client_config.ssl_ca_bundle.clone(),
                alpn_list: None,
            })
        } else {
            None
        };

        let cm_opts = ConnectionManagerOptions {
            host,
            port,
            max_connections: self.client_config.max_connections,
            max_connection_idle_ms: self.client_config.max_connection_idle_ms,
            connect_timeout_ms: self.client_config.connect_timeout_ms,
            tls_options,
            proxy_options: self.client_config.proxy.clone(),
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

fn parse_endpoint(endpoint: &str) -> Result<(String, String, u32), Error> {
    let (scheme, rest) = endpoint.split_once("://").ok_or_else(|| {
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

fn hash_get_string_required(hash: &RHash, key: &str) -> Result<String, Error> {
    hash_get_string(hash, key)?.ok_or_else(|| {
        Error::new(
            magnus::exception::arg_error(),
            format!("missing required option :{}", key),
        )
    })
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

            let host = hash_get_string(&proxy_hash, "host")?.ok_or_else(|| {
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

fn build_ruby_headers(ruby: &Ruby, headers: &[(String, String)]) -> RHash {
    let hash = RHash::new();
    for (name, value) in headers {
        let rb_name = ruby.str_new(name);
        let rb_value = ruby.str_new(value);
        // Check if the key already exists; if so, merge with ", "
        let existing: Option<Value> = hash.lookup(rb_name.as_value()).unwrap_or(None);
        match existing {
            Some(v) if !v.is_nil() => {
                // Merge: "existing_value, new_value"
                let existing_str = RString::from_value(v).unwrap();
                let merged = format!(
                    "{}, {}",
                    unsafe { std::str::from_utf8_unchecked(existing_str.as_slice()) },
                    value
                );
                let _ = hash.aset(rb_name.as_value(), ruby.str_new(&merged).as_value());
            }
            _ => {
                let _ = hash.aset(rb_name.as_value(), rb_value.as_value());
            }
        }
    }
    hash
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register the `AwsCrt::SignedHttpClient` class with magnus.
pub fn define_signed_http_client(
    ruby: &Ruby,
    module: &magnus::RModule,
) -> Result<(), Error> {
    let class = module.define_class("SignedHttpClient", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", magnus::function!(SignedHttpClient::rb_new, -1))?;
    class.define_method("request", method!(SignedHttpClient::rb_request, -1))?;

    Ok(())
}
