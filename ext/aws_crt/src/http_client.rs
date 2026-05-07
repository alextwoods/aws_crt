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

use base64::Engine;
use magnus::prelude::*;
use magnus::rb_sys::{AsRawValue, FromRawValue};
use magnus::scan_args::{get_kwargs, scan_args};
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::value::Lazy;
use magnus::{data_type_builder, method, Error, RArray, RClass, RHash, RString, Ruby, Symbol, Value};
use rb_sys::VALUE;

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn rb_thread_call_without_gvl(
        func: unsafe extern "C" fn(data: *mut std::ffi::c_void) -> *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
        ubf: *const std::ffi::c_void,
        ubf_data: *const std::ffi::c_void,
    ) -> *mut std::ffi::c_void;
}

use crate::connection_manager::{ConnectionManager, ConnectionManagerOptions};
use crate::file_part::FilePart;
use crate::http;
use crate::http_response::HttpResponse as RubyHttpResponse;
use crate::proxy::{ProxyAuthType, ProxyOptions};
use crate::sharable_string_io::SharableStringIO;
use crate::tls::TlsOptions;

// ---------------------------------------------------------------------------
// Response Target validation
// ---------------------------------------------------------------------------

/// The kind of response target provided by the user.
#[derive(Clone, Debug)]
pub enum ResponseTargetKind {
    Proc,
    FilePath,
    FileObject,
    OffsetFile,
}

/// Validate the `response_target` argument and return its kind.
///
/// Accepted types:
/// - Proc (checked via `is_a?(Proc)`)
/// - String (file path)
/// - Pathname (via const lookup on Object)
/// - File object (checked via `is_a?(File)`)
/// - Hash with `:path` (String) and `:offset` (non-negative Integer)
pub fn validate_response_target(ruby: &Ruby, target: Value) -> Result<ResponseTargetKind, Error> {
    // Check Proc
    let proc_class = ruby.class_object().const_get::<_, Value>("Proc").map_err(|_| {
        Error::new(magnus::exception::runtime_error(), "cannot resolve Proc class")
    })?;
    let is_proc: bool = target.funcall("is_a?", (proc_class,))?;
    if is_proc {
        return Ok(ResponseTargetKind::Proc);
    }

    // Check String
    if target.is_kind_of(ruby.class_string()) {
        return Ok(ResponseTargetKind::FilePath);
    }

    // Check Hash with :path and :offset (before Pathname to avoid calling methods on Hash)
    if let Some(hash) = RHash::from_value(target) {
        validate_offset_hash(&hash)?;
        return Ok(ResponseTargetKind::OffsetFile);
    }

    // Check Pathname (via const lookup — Pathname may not be loaded)
    if let Ok(pathname_class) = ruby.class_object().const_get::<_, Value>("Pathname") {
        let is_pathname: bool = target.funcall("is_a?", (pathname_class,))?;
        if is_pathname {
            return Ok(ResponseTargetKind::FilePath);
        }
    }

    // Check File
    let file_class = ruby.class_object().const_get::<_, Value>("File").map_err(|_| {
        Error::new(magnus::exception::runtime_error(), "cannot resolve File class")
    })?;
    let is_file: bool = target.funcall("is_a?", (file_class,))?;
    if is_file {
        return Ok(ResponseTargetKind::FileObject);
    }

    Err(Error::new(
        magnus::exception::arg_error(),
        "response_target must be a Proc, String, Pathname, File, or Hash with :path and :offset keys",
    ))
}

/// Validate that an offset hash has the required `:path` (String) and `:offset` (non-negative Integer) keys.
fn validate_offset_hash(hash: &RHash) -> Result<(), Error> {
    let path_sym = Symbol::new("path");
    let offset_sym = Symbol::new("offset");

    // Check :path key
    let path_val: Option<Value> = hash.lookup(path_sym)?;
    match path_val {
        Some(v) if !v.is_nil() => {
            // Verify it's a String
            if RString::from_value(v).is_none() {
                return Err(Error::new(
                    magnus::exception::arg_error(),
                    "response_target hash must include :path (String) and :offset (Integer) keys",
                ));
            }
        }
        _ => {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "response_target hash must include :path (String) and :offset (Integer) keys",
            ));
        }
    }

    // Check :offset key
    let offset_val: Option<Value> = hash.lookup(offset_sym)?;
    match offset_val {
        Some(v) if !v.is_nil() => {
            // Try to convert to i64 to check if it's an Integer
            let offset: i64 = magnus::TryConvert::try_convert(v).map_err(|_| {
                Error::new(
                    magnus::exception::arg_error(),
                    "response_target hash must include :path (String) and :offset (Integer) keys",
                )
            })?;
            if offset < 0 {
                return Err(Error::new(
                    magnus::exception::arg_error(),
                    "response_target offset must be non-negative",
                ));
            }
        }
        _ => {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "response_target hash must include :path (String) and :offset (Integer) keys",
            ));
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// GVL-free file write helper
// ---------------------------------------------------------------------------

/// Write data to a file at the given byte offset, releasing the GVL during I/O.
///
/// This enables the Ruby fiber scheduler to run other fibers while the write
/// completes. Reuses the same `rb_thread_call_without_gvl` pattern as
/// `SharableStringIO#write_to_file`.
///
/// Returns the number of bytes written on success, or an IOError on failure
/// with the file path and underlying OS error in the message.
pub fn write_to_file_gvl_free(path: &str, offset: u64, data: &[u8]) -> Result<usize, Error> {
    if data.is_empty() {
        return Ok(0);
    }

    let path_c = std::ffi::CString::new(path)
        .map_err(|_| Error::new(magnus::exception::arg_error(), "path contains null byte"))?;

    struct WriteData {
        path: std::ffi::CString,
        data: Vec<u8>,
        offset: u64,
        result: std::result::Result<usize, std::io::Error>,
    }

    let mut write_data = WriteData {
        path: path_c,
        data: data.to_vec(),
        offset,
        result: Ok(0),
    };

    unsafe extern "C" fn do_write(ptr: *mut std::ffi::c_void) -> *mut std::ffi::c_void {
        let wd = &mut *(ptr as *mut WriteData);
        wd.result = (|| {
            use std::fs::OpenOptions;
            use std::io::{Seek, SeekFrom, Write};

            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .open(wd.path.to_str().unwrap())?;

            if wd.offset > 0 {
                file.seek(SeekFrom::Start(wd.offset))?;
            }
            file.write_all(&wd.data)?;
            Ok(wd.data.len())
        })();
        std::ptr::null_mut()
    }

    // Release GVL during the file write — enables fiber scheduler to
    // switch to other fibers while this one blocks on I/O.
    unsafe {
        rb_thread_call_without_gvl(
            do_write,
            &mut write_data as *mut WriteData as *mut std::ffi::c_void,
            std::ptr::null(),
            std::ptr::null(),
        );
    }

    write_data.result.map_err(|e| {
        if offset > 0 {
            Error::new(
                magnus::exception::io_error(),
                format!("response_target write failed for '{}' at offset {}: {}", path, offset, e),
            )
        } else {
            Error::new(
                magnus::exception::io_error(),
                format!("response_target write failed for '{}': {}", path, e),
            )
        }
    })
}

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

    /// Ruby: `client.request(endpoint, method, path, headers, body = nil,
    ///          streaming_io: false, on_data: nil, checksum_algorithms: nil, &block)`
    ///
    /// Always returns an `AwsCrt::Http::Response` instance.
    fn rb_request(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<Value, Error> {
        let args = scan_args::<(String, String, String, RArray), (Option<Value>,), (), (), RHash, ()>(args)?;
        let endpoint = args.required.0;
        let method = args.required.1;
        let path = args.required.2;
        let headers = args.required.3;
        let body_val = args.optional.0;

        // Extract keyword arguments
        let kwargs = get_kwargs::<_, (), (Option<bool>, Option<Value>, Option<Value>, Option<Value>, Option<Value>), ()>(
            args.keywords, &[], &["streaming_io", "on_data", "on_headers", "checksum_algorithms", "response_target"]
        )?;
        let (streaming_io_opt, on_data_opt, on_headers_opt, checksum_algorithms_opt, response_target_opt) = kwargs.optional;
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

        // Validate response_target if provided
        let response_target_kind: Option<ResponseTargetKind> = match &response_target_opt {
            Some(v) if !v.is_nil() => {
                Some(validate_response_target(ruby, *v)?)
            }
            _ => None,
        };

        // Validate: response_target and block are mutually exclusive
        if response_target_kind.is_some() && block {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "response_target and block are mutually exclusive",
            ));
        }

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
        // Supports: String, FilePart, or nil
        let body_bytes: Option<Vec<u8>> = match body_val {
            Some(v) if !v.is_nil() => {
                // Check if it's a FilePart (optimized native path)
                if let Ok(fp) = <typed_data::Obj<FilePart>>::try_convert(v) {
                    let bytes = FilePart::read_bytes(&fp)?;
                    if bytes.is_empty() { None } else { Some(bytes) }
                } else {
                    // Treat as String (or convert to String)
                    let s = RString::from_value(v).ok_or_else(|| {
                        Error::new(
                            magnus::exception::type_error(),
                            "body must be a String, FilePart, or nil",
                        )
                    })?;
                    let slice = unsafe { s.as_slice() };
                    if slice.is_empty() { None } else { Some(slice.to_vec()) }
                }
            }
            _ => None,
        };

        if let Some(ref target_kind) = response_target_kind {
            // response_target path: always use buffered make_request, then
            // dispatch to target on success (2xx) or return body normally on failure.
            let response_target_val = response_target_opt.unwrap();

            let response = http::make_request(
                cm_ptr,
                &method,
                &path,
                &header_vec,
                body_bytes,
                read_timeout_ms,
            )
            .map_err(|e| -> Error { e.into() })?;

            // Compute checksum over the body buffer
            let (checksum_algorithm, computed_checksum) =
                compute_checksum(&checksum_algorithms, &response.headers, &response.body);

            let rb_headers = build_ruby_headers_hash(ruby, &response.headers);

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

            // Notify on_data listeners with the actual body bytes
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

            // Check status code: dispatch to target on 2xx, ignore on non-2xx
            let is_success = (200..=299).contains(&response.status_code);

            if is_success {
                // Dispatch to target based on kind
                let response_target_info_raw: rb_sys::VALUE = match target_kind {
                    ResponseTargetKind::Proc => {
                        // Call the Proc with (body_string, headers_hash)
                        let rb_body_str = ruby.str_from_slice(&response.body);
                        let rb_headers_value: Value = unsafe { Value::from_raw(rb_headers.as_raw()) };
                        let _: Value = response_target_val.funcall("call", (rb_body_str, rb_headers_value))?;

                        // Build response_target_info: { type: :proc }
                        let info = RHash::new();
                        let _ = info.aset(Symbol::new("type"), Symbol::new("proc"));
                        info.as_raw()
                    }
                    ResponseTargetKind::FilePath => {
                        // Extract path string — handle both String and Pathname
                        let path_str: String = if response_target_val.is_kind_of(ruby.class_string()) {
                            magnus::TryConvert::try_convert(response_target_val)?
                        } else {
                            // Pathname — call to_s
                            response_target_val.funcall("to_s", ())?
                        };

                        write_to_file_gvl_free(&path_str, 0, &response.body)?;

                        // Build response_target_info: { type: :file, path: "<path>" }
                        let info = RHash::new();
                        let _ = info.aset(Symbol::new("type"), Symbol::new("file"));
                        let _ = info.aset(Symbol::new("path"), ruby.str_new(&path_str));
                        info.as_raw()
                    }
                    ResponseTargetKind::FileObject => {
                        // Get path from the File object
                        let path_str: String = response_target_val.funcall("path", ())?;

                        write_to_file_gvl_free(&path_str, 0, &response.body)?;

                        // Build response_target_info: { type: :file, path: "<path>" }
                        let info = RHash::new();
                        let _ = info.aset(Symbol::new("type"), Symbol::new("file"));
                        let _ = info.aset(Symbol::new("path"), ruby.str_new(&path_str));
                        info.as_raw()
                    }
                    ResponseTargetKind::OffsetFile => {
                        // Extract :path and :offset from hash
                        let hash = RHash::from_value(response_target_val).unwrap();
                        let path_val: Option<Value> = hash.lookup(Symbol::new("path"))?;
                        let path_str: String = magnus::TryConvert::try_convert(path_val.unwrap())?;
                        let offset_val: Option<Value> = hash.lookup(Symbol::new("offset"))?;
                        let offset: i64 = magnus::TryConvert::try_convert(offset_val.unwrap())?;

                        write_to_file_gvl_free(&path_str, offset as u64, &response.body)?;

                        // Build response_target_info: { type: :offset_file, path: "<path>", offset: <n> }
                        let info = RHash::new();
                        let _ = info.aset(Symbol::new("type"), Symbol::new("offset_file"));
                        let _ = info.aset(Symbol::new("path"), ruby.str_new(&path_str));
                        let _ = info.aset(Symbol::new("offset"), ruby.into_value(offset));
                        info.as_raw()
                    }
                };

                // On success: body is empty SharableStringIO
                let empty_sio = SharableStringIO::new_with_buffer(Vec::new());

                let resp_obj = RubyHttpResponse::new_from_parts(
                    response.status_code,
                    rb_headers.as_raw(),
                    empty_sio.as_value().as_raw(),
                    checksum_algorithm,
                    computed_checksum,
                    response_target_info_raw,
                );
                Ok(resp_obj.as_value())
            } else {
                // Non-success: ignore target, return body normally
                // Body format depends on streaming_io setting
                let rb_body_raw: rb_sys::VALUE = if streaming_io {
                    // streaming_io: true → SharableStringIO
                    let sio = SharableStringIO::new_with_buffer(response.body);
                    sio.as_value().as_raw()
                } else {
                    // streaming_io: false (default) → String
                    let rb_body = ruby.str_from_slice(&response.body);
                    rb_body.as_value().as_raw()
                };

                let resp_obj = RubyHttpResponse::new_from_parts(
                    response.status_code,
                    rb_headers.as_raw(),
                    rb_body_raw,
                    checksum_algorithm,
                    computed_checksum,
                    rb_sys::Qnil as VALUE,
                );
                Ok(resp_obj.as_value())
            }
        } else if streaming_io {
            // streaming_io path: use make_request (buffered), then wrap body
            // in a SharableStringIO.
            let response = http::make_request(
                cm_ptr,
                &method,
                &path,
                &header_vec,
                body_bytes,
                read_timeout_ms,
            )
            .map_err(|e| -> Error { e.into() })?;

            // Compute checksum over the body buffer
            let (checksum_algorithm, computed_checksum) =
                compute_checksum(&checksum_algorithms, &response.headers, &response.body);

            let rb_headers = build_ruby_headers_hash(ruby, &response.headers);

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

            let resp_obj = RubyHttpResponse::new_from_parts(
                response.status_code,
                rb_headers.as_raw(),
                sio.as_value().as_raw(),
                checksum_algorithm,
                computed_checksum,
                rb_sys::Qnil as VALUE,
            );
            Ok(resp_obj.as_value())
        } else if block {
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
            .map_err(|e| -> Error { e.into() })?;

            let rb_headers = build_ruby_headers_hash(ruby, &captured_headers);

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

            // Block streaming path: no native checksum computation
            let resp_obj = RubyHttpResponse::new_from_parts(
                captured_status,
                rb_headers.as_raw(),
                ruby.qnil().as_value().as_raw(),
                None,
                None,
                rb_sys::Qnil as VALUE,
            );
            Ok(resp_obj.as_value())
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

            // Compute checksum over the body buffer
            let (checksum_algorithm, computed_checksum) =
                compute_checksum(&checksum_algorithms, &response.headers, &response.body);

            let rb_headers = build_ruby_headers_hash(ruby, &response.headers);

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

            let resp_obj = RubyHttpResponse::new_from_parts(
                response.status_code,
                rb_headers.as_raw(),
                rb_body.as_value().as_raw(),
                checksum_algorithm,
                computed_checksum,
                rb_sys::Qnil as VALUE,
            );
            Ok(resp_obj.as_value())
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
// Checksum computation
// ---------------------------------------------------------------------------

/// Compute a checksum over the response body based on the requested algorithms
/// and the response headers.
///
/// Returns (algorithm_name, base64_checksum) if a matching header was found,
/// or (None, None) if no match.
pub fn compute_checksum(
    algorithms: &Option<Vec<String>>,
    response_headers: &[(String, String)],
    body: &[u8],
) -> (Option<String>, Option<String>) {
    let algs = match algorithms {
        Some(a) if !a.is_empty() => a,
        _ => return (None, None),
    };

    // Find the first algorithm whose corresponding header exists in the response
    for alg in algs {
        let header_name = format!("x-amz-checksum-{}", alg.to_lowercase());
        let has_header = response_headers.iter().any(|(name, _)| {
            name.eq_ignore_ascii_case(&header_name)
        });

        if has_header {
            // Compute the checksum
            let checksum_b64 = compute_checksum_for_algorithm(alg, body);
            return match checksum_b64 {
                Some(cs) => (Some(alg.clone()), Some(cs)),
                None => (None, None), // Unknown algorithm
            };
        }
    }

    (None, None)
}

/// Compute the checksum for a specific algorithm over the given data.
/// Returns the base64-encoded result, or None if the algorithm is unknown.
pub fn compute_checksum_for_algorithm(algorithm: &str, data: &[u8]) -> Option<String> {
    let engine = base64::engine::general_purpose::STANDARD;

    match algorithm.to_uppercase().as_str() {
        "CRC32" => {
            let crc = unsafe {
                crate::crt::aws_checksums_crc32_ex(data.as_ptr(), data.len(), 0)
            };
            // Pack as 4 bytes big-endian, then base64
            let bytes = crc.to_be_bytes();
            Some(engine.encode(bytes))
        }
        "CRC32C" => {
            let crc = unsafe {
                crate::crt::aws_checksums_crc32c_ex(data.as_ptr(), data.len(), 0)
            };
            let bytes = crc.to_be_bytes();
            Some(engine.encode(bytes))
        }
        "CRC64NVME" => {
            let crc = unsafe {
                crate::crt::aws_checksums_crc64nvme_ex(data.as_ptr(), data.len(), 0)
            };
            // Pack as 8 bytes big-endian, then base64
            let bytes = crc.to_be_bytes();
            Some(engine.encode(bytes))
        }
        "SHA256" => {
            compute_sha_checksum(data, ShaAlgorithm::Sha256)
        }
        "SHA1" => {
            compute_sha_checksum(data, ShaAlgorithm::Sha1)
        }
        _ => None,
    }
}

pub enum ShaAlgorithm {
    Sha1,
    Sha256,
}

/// Compute SHA1 or SHA256 using the CRT one-shot functions.
pub fn compute_sha_checksum(data: &[u8], algorithm: ShaAlgorithm) -> Option<String> {
    let engine = base64::engine::general_purpose::STANDARD;

    unsafe {
        let allocator = crate::crt::aws_default_allocator();

        // Determine output capacity
        let capacity = match algorithm {
            ShaAlgorithm::Sha1 => 20usize,
            ShaAlgorithm::Sha256 => 32usize,
        };

        // Initialize output buffer
        let mut output = crate::crt::AwsByteBuf {
            len: 0,
            buffer: std::ptr::null_mut(),
            capacity: 0,
            allocator: std::ptr::null_mut(),
        };

        let rc = crate::crt::aws_byte_buf_init(
            &mut output,
            allocator,
            capacity,
        );
        if rc != 0 {
            return None;
        }

        // Set up input cursor
        let input = crate::crt::AwsByteCursor {
            len: data.len(),
            ptr: data.as_ptr(),
        };

        let result = match algorithm {
            ShaAlgorithm::Sha1 => {
                crate::crt::aws_sha1_compute(allocator, &input, &mut output, 0)
            }
            ShaAlgorithm::Sha256 => {
                crate::crt::aws_sha256_compute(allocator, &input, &mut output, 0)
            }
        };

        if result != 0 {
            crate::crt::aws_byte_buf_clean_up(&mut output);
            return None;
        }

        // Read the digest bytes
        let digest = std::slice::from_raw_parts(output.buffer, output.len);
        let encoded = engine.encode(digest);

        crate::crt::aws_byte_buf_clean_up(&mut output);

        Some(encoded)
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

/// Convert response headers to a Ruby Hash with String keys and String values.
/// Duplicate header names are merged into comma-separated values (per HTTP spec),
/// matching the behavior expected by consumers like the SDK's flexible checksum plugin.
fn build_ruby_headers_hash(ruby: &Ruby, headers: &[(String, String)]) -> RHash {
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
