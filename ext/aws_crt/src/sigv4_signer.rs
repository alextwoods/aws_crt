//! CRT-backed SigV4 request signer.
//!
//! Provides a standalone request signer that uses the CRT's
//! `aws_sign_request_aws` to sign HTTP requests with SigV4. The signer
//! builds a CRT HTTP message from the Ruby-provided request components,
//! signs it asynchronously (releasing the GVL during the wait), applies
//! the signing result, and extracts the signed headers back to Ruby.
//!
//! Performance focus:
//! - Single Rust call per sign operation (no round-trips)
//! - GVL released during the async CRT signing callback
//! - Zero-copy byte cursors for header/body data where possible
//! - Pre-allocated header vectors sized from input

use std::cell::RefCell;
use std::sync::{Arc, Condvar, Mutex};

use magnus::prelude::*;
use magnus::typed_data;
use magnus::{method, Error, RArray, RHash, Ruby, Symbol, Value};

use crate::credentials::{AwsCredentialsProvider, CredentialsProvider};
use crate::error::CrtError;
use crate::http::{
    AwsByteCursor, AwsHttpHeader, AwsHttpMessage, AwsInputStream,
    aws_default_allocator, aws_http_message_add_header, aws_http_message_new_request,
    aws_http_message_release, aws_http_message_set_body_stream,
    aws_http_message_set_request_method, aws_http_message_set_request_path,
    aws_input_stream_new_from_cursor, aws_input_stream_release,
};
use crate::runtime::AwsAllocator;

// ---------------------------------------------------------------------------
// Opaque CRT types (signing-specific, not shared with http.rs)
// ---------------------------------------------------------------------------

#[repr(C)]
struct AwsSignable {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AwsSigningResult {
    _opaque: [u8; 0],
}

/// Mirrors `struct aws_signing_config_base`.
#[repr(C)]
struct AwsSigningConfigBase {
    _config_type: u32,
}

// ---------------------------------------------------------------------------
// FFI declarations (signing-specific)
// ---------------------------------------------------------------------------

extern "C" {
    // Auth library init
    fn aws_auth_library_init(allocator: *mut AwsAllocator);

    // Header access (used to extract signed headers)
    fn aws_http_message_get_header_count(message: *const AwsHttpMessage) -> usize;
    fn aws_http_message_get_header(
        message: *const AwsHttpMessage,
        header_out: *mut AwsHttpHeader,
        index: usize,
    ) -> i32;

    // Signable
    fn aws_signable_new_http_request(
        allocator: *mut AwsAllocator,
        request: *mut AwsHttpMessage,
    ) -> *mut AwsSignable;
    fn aws_signable_destroy(signable: *mut AwsSignable);

    // Signing
    fn aws_sign_request_aws(
        allocator: *mut AwsAllocator,
        signable: *const AwsSignable,
        base_config: *const AwsSigningConfigBase,
        on_complete: unsafe extern "C" fn(
            result: *mut AwsSigningResult,
            error_code: i32,
            userdata: *mut std::ffi::c_void,
        ),
        userdata: *mut std::ffi::c_void,
    ) -> i32;

    // Apply signing result to HTTP request
    fn aws_apply_signing_result_to_http_request(
        request: *mut AwsHttpMessage,
        allocator: *mut AwsAllocator,
        result: *const AwsSigningResult,
    ) -> i32;

    // Ruby GVL management
    fn rb_thread_call_without_gvl(
        func: unsafe extern "C" fn(data: *mut std::ffi::c_void) -> *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
        ubf: *const std::ffi::c_void,
        ubf_data: *const std::ffi::c_void,
    ) -> *mut std::ffi::c_void;

    // C helper for signing config initialization (signing_config_init.c)
    fn aws_crt_init_signing_config(
        config_buf: *mut std::ffi::c_void,
        region: *const u8,
        region_len: usize,
        service: *const u8,
        service_len: usize,
        credentials_provider: *mut AwsCredentialsProvider,
        use_double_uri_encode: i32,
        should_normalize_uri_path: i32,
        signed_body_header: i32,
        signed_body_value: *const u8,
        signed_body_value_len: usize,
    );

    fn aws_crt_signing_config_size() -> usize;
}

// ---------------------------------------------------------------------------
// Signing state for async callback
// ---------------------------------------------------------------------------

struct SigningState {
    error_code: i32,
    complete: bool,
    /// The HTTP request message — signing result is applied to it in the callback.
    request: *mut AwsHttpMessage,
}

unsafe impl Send for SigningState {}

type SharedSigningState = Arc<(Mutex<SigningState>, Condvar)>;

/// Signing completion callback — runs on the CRT event loop thread.
unsafe extern "C" fn on_signing_complete(
    result: *mut AwsSigningResult,
    error_code: i32,
    userdata: *mut std::ffi::c_void,
) {
    let state = &*(userdata as *const SharedSigningState);
    let mut guard = state.0.lock().unwrap();

    if error_code == 0 && !result.is_null() {
        // Apply the signing result to the HTTP request in-place.
        // This adds Authorization, X-Amz-Date, x-amz-content-sha256, etc.
        let allocator = aws_default_allocator();
        let rc = aws_apply_signing_result_to_http_request(guard.request, allocator, result);
        if rc != 0 {
            guard.error_code = -1;
        }
    } else {
        guard.error_code = error_code;
    }

    guard.complete = true;
    state.1.notify_one();
}

/// Wait function called without the GVL.
unsafe extern "C" fn wait_for_signing(
    data: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
    let state = &*(data as *const SharedSigningState);
    let mut guard = state.0.lock().unwrap();
    while !guard.complete {
        guard = state.1.wait(guard).unwrap();
    }
    std::ptr::null_mut()
}

// ---------------------------------------------------------------------------
// Core signing function (public for reuse by signed_http_client)
// ---------------------------------------------------------------------------

/// Sign a CRT HTTP message in-place using SigV4.
///
/// This is the core signing function used by both the standalone signer
/// and the combined signer+client. It signs the message asynchronously
/// (releasing the GVL during the wait) and applies the signing result
/// directly to the message's headers.
///
/// # Arguments
/// * `request` - A valid CRT HTTP message to sign in-place
/// * `region` - AWS region
/// * `service` - AWS service name
/// * `credentials_provider` - CRT credentials provider
/// * `apply_sha256_header` - Whether to add x-amz-content-sha256
/// * `use_double_uri_encode` - Whether to double-encode URI
/// * `normalize_uri_path` - Whether to normalize URI path
/// * `sign_body` - Whether to compute SHA-256 of body
///
/// # Returns
/// `Ok(())` on success (message is signed in-place), or `CrtError` on failure.
pub fn sign_crt_message(
    request: *mut AwsHttpMessage,
    region: &str,
    service: &str,
    credentials_provider: &CredentialsProvider,
    apply_sha256_header: bool,
    use_double_uri_encode: bool,
    normalize_uri_path: bool,
    sign_body: bool,
) -> Result<(), CrtError> {
    let allocator = unsafe { aws_default_allocator() };

    // Ensure auth library is initialized
    static AUTH_INIT: std::sync::Once = std::sync::Once::new();
    AUTH_INIT.call_once(|| unsafe {
        aws_auth_library_init(allocator);
    });

    // Build the signed_body_value
    let unsigned_payload = b"UNSIGNED-PAYLOAD";
    let (sbv_ptr, sbv_len) = if sign_body {
        (std::ptr::null(), 0usize)
    } else {
        (unsigned_payload.as_ptr(), unsigned_payload.len())
    };

    let signed_body_header: i32 = if apply_sha256_header { 1 } else { 0 };

    // Allocate the signing config buffer
    let config_size = unsafe { aws_crt_signing_config_size() };
    let mut config_buf: Vec<u8> = vec![0u8; config_size];

    // Own the region and service strings so the byte cursors remain valid
    let region_owned = region.to_string();
    let service_owned = service.to_string();

    unsafe {
        aws_crt_init_signing_config(
            config_buf.as_mut_ptr() as *mut std::ffi::c_void,
            region_owned.as_ptr(),
            region_owned.len(),
            service_owned.as_ptr(),
            service_owned.len(),
            credentials_provider.as_ptr(),
            if use_double_uri_encode { 1 } else { 0 },
            if normalize_uri_path { 1 } else { 0 },
            signed_body_header,
            sbv_ptr,
            sbv_len,
        );
    }

    // Create signable from the HTTP request
    let signable = unsafe { aws_signable_new_http_request(allocator, request) };
    if signable.is_null() {
        return Err(CrtError::last_error());
    }

    // Set up shared state for async signing
    let state: SharedSigningState = Arc::new((
        Mutex::new(SigningState {
            error_code: 0,
            complete: false,
            request,
        }),
        Condvar::new(),
    ));

    // Initiate signing
    let rc = unsafe {
        aws_sign_request_aws(
            allocator,
            signable,
            config_buf.as_ptr() as *const AwsSigningConfigBase,
            on_signing_complete,
            &state as *const SharedSigningState as *mut std::ffi::c_void,
        )
    };

    if rc != 0 {
        unsafe { aws_signable_destroy(signable) };
        return Err(CrtError::last_error());
    }

    // Release GVL and wait for signing to complete
    unsafe {
        rb_thread_call_without_gvl(
            wait_for_signing,
            &state as *const SharedSigningState as *mut std::ffi::c_void,
            std::ptr::null(),
            std::ptr::null(),
        );
    }

    // Clean up signable
    unsafe { aws_signable_destroy(signable) };

    // Check for errors
    let error_code = {
        let guard = state.0.lock().unwrap();
        guard.error_code
    };

    if error_code != 0 {
        return Err(CrtError::from_code(error_code));
    }

    Ok(())
}

/// Sign an HTTP request using SigV4 and return the signed headers.
///
/// Builds a CRT HTTP message, signs it in-place, and extracts the signed
/// headers. This is the function used by the standalone `Sigv4Signer`.
fn sign_request(
    region: &str,
    service: &str,
    credentials_provider: &CredentialsProvider,
    method: &str,
    uri: &str,
    headers: &[(String, String)],
    body: Option<&[u8]>,
    apply_sha256_header: bool,
    use_double_uri_encode: bool,
    normalize_uri_path: bool,
    sign_body: bool,
) -> Result<Vec<(String, String)>, CrtError> {
    let allocator = unsafe { aws_default_allocator() };

    // Ensure auth library is initialized (sign_crt_message also does this,
    // but we need it for message construction too)
    static AUTH_INIT: std::sync::Once = std::sync::Once::new();
    AUTH_INIT.call_once(|| unsafe {
        aws_auth_library_init(allocator);
    });

    // Build the CRT HTTP message
    let request = unsafe { aws_http_message_new_request(allocator) };
    if request.is_null() {
        return Err(CrtError::last_error());
    }

    // Set method
    unsafe {
        if aws_http_message_set_request_method(request, AwsByteCursor::from_slice(method.as_bytes())) != 0 {
            aws_http_message_release(request);
            return Err(CrtError::last_error());
        }
    }

    // Set path (URI)
    unsafe {
        if aws_http_message_set_request_path(request, AwsByteCursor::from_slice(uri.as_bytes())) != 0 {
            aws_http_message_release(request);
            return Err(CrtError::last_error());
        }
    }

    // Add headers
    for (name, value) in headers {
        let header = AwsHttpHeader {
            name: AwsByteCursor::from_slice(name.as_bytes()),
            value: AwsByteCursor::from_slice(value.as_bytes()),
            compression: 0,
            _pad: 0,
        };
        unsafe {
            if aws_http_message_add_header(request, header) != 0 {
                aws_http_message_release(request);
                return Err(CrtError::last_error());
            }
        }
    }

    // Set body stream if provided
    let mut body_stream: *mut AwsInputStream = std::ptr::null_mut();
    if let Some(body_bytes) = body {
        if !body_bytes.is_empty() {
            let cursor = AwsByteCursor::from_slice(body_bytes);
            body_stream = unsafe { aws_input_stream_new_from_cursor(allocator, &cursor) };
            if body_stream.is_null() {
                unsafe { aws_http_message_release(request) };
                return Err(CrtError::last_error());
            }
            unsafe { aws_http_message_set_body_stream(request, body_stream) };
        }
    }

    // Sign the message in-place
    let sign_result = sign_crt_message(
        request,
        region,
        service,
        credentials_provider,
        apply_sha256_header,
        use_double_uri_encode,
        normalize_uri_path,
        sign_body,
    );

    if let Err(e) = sign_result {
        if !body_stream.is_null() {
            unsafe { aws_input_stream_release(body_stream) };
        }
        unsafe { aws_http_message_release(request) };
        return Err(e);
    }

    // Extract signed headers from the request
    let header_count = unsafe { aws_http_message_get_header_count(request) };
    let mut signed_headers: Vec<(String, String)> = Vec::with_capacity(header_count);

    for i in 0..header_count {
        let mut header = AwsHttpHeader {
            name: AwsByteCursor::from_slice(&[]),
            value: AwsByteCursor::from_slice(&[]),
            compression: 0,
            _pad: 0,
        };
        unsafe {
            if aws_http_message_get_header(request, &mut header, i) == 0 {
                let name = std::str::from_utf8_unchecked(std::slice::from_raw_parts(
                    header.name.ptr,
                    header.name.len,
                ))
                .to_string();
                let value = std::str::from_utf8_unchecked(std::slice::from_raw_parts(
                    header.value.ptr,
                    header.value.len,
                ))
                .to_string();
                signed_headers.push((name, value));
            }
        }
    }

    // Clean up
    if !body_stream.is_null() {
        unsafe { aws_input_stream_release(body_stream) };
    }
    unsafe { aws_http_message_release(request) };

    Ok(signed_headers)
}

// ---------------------------------------------------------------------------
// Ruby-facing class: AwsCrt::Sigv4Signer
// ---------------------------------------------------------------------------

/// Ruby class `AwsCrt::Sigv4Signer`.
///
/// A reusable SigV4 request signer. Holds the service and default signing
/// options. Credentials and region are provided per-call to support
/// credential rotation and multi-region use.
#[magnus::wrap(class = "AwsCrt::Sigv4Signer", free_immediately, size)]
pub struct RubySigv4Signer {
    inner: RefCell<Option<SignerConfig>>,
}

struct SignerConfig {
    service: String,
    apply_sha256_header: bool,
    use_double_uri_encode: bool,
    normalize_uri_path: bool,
    sign_body: bool,
}

impl Default for RubySigv4Signer {
    fn default() -> Self {
        Self {
            inner: RefCell::new(None),
        }
    }
}

// ---------------------------------------------------------------------------
// Hash extraction helpers
// ---------------------------------------------------------------------------

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

fn hash_get_bool(hash: &RHash, key: &str, default: bool) -> Result<bool, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => Ok(magnus::TryConvert::try_convert(v)?),
        None => Ok(default),
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl RubySigv4Signer {
    /// Ruby: `AwsCrt::Sigv4Signer.new(options)`
    ///
    /// options Hash:
    ///   :service (required) — AWS service name (e.g. "s3", "sts", "dynamodb")
    ///   :apply_sha256_header (optional, default true) — add x-amz-content-sha256
    ///   :use_double_uri_encode (optional, default true) — double-encode URI
    ///   :normalize_uri_path (optional, default true) — normalize URI path
    ///   :sign_body (optional, default false) — compute SHA-256 of body
    fn rb_initialize(rb_self: &Self, options: RHash) -> Result<(), Error> {
        let service = hash_get_string_required(&options, "service")?;
        let apply_sha256_header = hash_get_bool(&options, "apply_sha256_header", true)?;
        let use_double_uri_encode = hash_get_bool(&options, "use_double_uri_encode", true)?;
        let normalize_uri_path = hash_get_bool(&options, "normalize_uri_path", true)?;
        let sign_body = hash_get_bool(&options, "sign_body", false)?;

        *rb_self.inner.borrow_mut() = Some(SignerConfig {
            service,
            apply_sha256_header,
            use_double_uri_encode,
            normalize_uri_path,
            sign_body,
        });

        Ok(())
    }

    /// Ruby: `signer.sign_request(request)`
    ///
    /// request Hash:
    ///   :region (required) — AWS region
    ///   :access_key_id (required) — AWS access key
    ///   :secret_access_key (required) — AWS secret key
    ///   :session_token (optional) — AWS session token
    ///   :method (required) — HTTP method (GET, POST, etc.)
    ///   :uri (required) — request URI path with query string
    ///   :headers (required) — Array of [name, value] pairs
    ///   :body (optional) — request body as String
    ///
    /// Returns: Hash with:
    ///   :headers — Array of [name, value] pairs (signed)
    ///   :method — HTTP method (unchanged)
    ///   :uri — URI path (unchanged)
    fn rb_sign_request(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        request: RHash,
    ) -> Result<Value, Error> {
        let inner = rb_self.inner.borrow();
        let config = inner.as_ref().ok_or_else(|| {
            Error::new(
                ruby.exception_runtime_error(),
                "Sigv4Signer not initialized",
            )
        })?;

        // Extract request parameters
        let region = hash_get_string_required(&request, "region")?;
        let access_key_id = hash_get_string_required(&request, "access_key_id")?;
        let secret_access_key = hash_get_string_required(&request, "secret_access_key")?;
        let session_token = hash_get_string(&request, "session_token")?;
        let method = hash_get_string_required(&request, "method")?;
        let uri = hash_get_string_required(&request, "uri")?;

        // Extract headers: Array of [name, value] pairs
        let headers_val: RArray = request
            .fetch::<_, RArray>(Symbol::new("headers"))
            .map_err(|_| {
                Error::new(
                    magnus::exception::arg_error(),
                    "missing required option :headers (Array of [name, value] pairs)",
                )
            })?;

        let header_len = headers_val.len();
        let mut headers: Vec<(String, String)> = Vec::with_capacity(header_len);
        for i in 0..header_len {
            let pair: RArray = headers_val.entry(i as isize)?;
            let name: String = pair.entry(0)?;
            let value: String = pair.entry(1)?;
            headers.push((name, value));
        }

        // Extract optional body
        let body_val = hash_get_string(&request, "body")?;
        let body_bytes: Option<Vec<u8>> = body_val.map(|s| s.into_bytes());

        // Create credentials provider
        let creds_provider = CredentialsProvider::new_static(
            &access_key_id,
            &secret_access_key,
            session_token.as_deref(),
        )
        .map_err(|e| -> Error { e.into() })?;

        // Sign the request
        let signed_headers = sign_request(
            &region,
            &config.service,
            &creds_provider,
            &method,
            &uri,
            &headers,
            body_bytes.as_deref(),
            config.apply_sha256_header,
            config.use_double_uri_encode,
            config.normalize_uri_path,
            config.sign_body,
        )
        .map_err(|e| -> Error { e.into() })?;

        // Build the result hash
        let result = RHash::new();

        // Build signed headers array
        let rb_headers = RArray::with_capacity(signed_headers.len());
        for (name, value) in &signed_headers {
            let pair = RArray::from_slice(&[
                ruby.str_new(name).as_value(),
                ruby.str_new(value).as_value(),
            ]);
            let _ = rb_headers.push(pair);
        }
        result.aset(Symbol::new("headers"), rb_headers)?;
        result.aset(Symbol::new("method"), ruby.str_new(&method).as_value())?;
        result.aset(Symbol::new("uri"), ruby.str_new(&uri).as_value())?;

        Ok(result.as_value())
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register the `AwsCrt::Sigv4Signer` class with magnus.
pub fn define_sigv4_signer(
    ruby: &Ruby,
    module: &magnus::RModule,
) -> Result<(), Error> {
    let class = module.define_class("Sigv4Signer", ruby.class_object())?;
    class.define_alloc_func::<RubySigv4Signer>();
    class.define_method("initialize", method!(RubySigv4Signer::rb_initialize, 1))?;
    class.define_method("sign_request", method!(RubySigv4Signer::rb_sign_request, 1))?;

    Ok(())
}
