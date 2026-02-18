//! S3 meta-request execution with GVL management.
//!
//! Handles the async meta-request lifecycle: building HTTP request messages,
//! configuring CRT meta-request options, managing callbacks from CRT event
//! loop threads, and releasing the Ruby GVL during blocking waits.
//!
//! The pattern mirrors `http.rs`: shared state is protected by a Mutex +
//! Condvar, CRT callbacks push data into the shared state, and the Ruby
//! thread blocks (without the GVL) on the condvar until the finish callback
//! signals completion.
//!
//! # Body Handling Modes
//!
//! **GET (get_object)**:
//! - `recv_filepath`: CRT writes directly to file via parallel I/O (fastest)
//! - IO streaming: body chunks written to an IO object via callback
//! - Block streaming: body chunks yielded to a Ruby block via callback
//! - Buffered: complete body accumulated in memory
//!
//! **PUT (put_object)**:
//! - `send_filepath`: CRT reads directly from file via parallel I/O (fastest)
//! - Buffer (String): in-memory body bytes passed to CRT
//! - Read+buffer (IO): IO contents read into memory, then passed to CRT

use std::ffi::CString;
use std::sync::{Arc, Condvar, Mutex};

use crate::credentials::AwsByteCursor;
use crate::error::CrtError;
use crate::runtime::AwsAllocator;
use crate::s3_client::AwsS3Client;
use crate::signing::AwsSigningConfigAws;

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

/// Opaque CRT HTTP message (same type as in http.rs, but we define our own
/// to avoid coupling the modules).
#[repr(C)]
pub struct AwsHttpMessage {
    _opaque: [u8; 0],
}

/// Opaque CRT S3 meta-request handle.
#[repr(C)]
struct AwsS3MetaRequest {
    _opaque: [u8; 0],
}

/// Opaque CRT input stream.
#[repr(C)]
struct AwsInputStream {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// FFI struct mirrors
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_http_header` from aws-c-http.
#[repr(C)]
struct AwsHttpHeader {
    name: AwsByteCursor,
    value: AwsByteCursor,
    compression: u32,
    _pad: u32,
}

/// CRT S3 meta-request types.
const AWS_S3_META_REQUEST_TYPE_GET_OBJECT: i32 = 1;
const AWS_S3_META_REQUEST_TYPE_PUT_OBJECT: i32 = 2;

/// CRT checksum algorithm enum values.
const AWS_SCA_NONE: i32 = 0;
const AWS_SCA_CRC32C: i32 = 1;
const AWS_SCA_CRC32: i32 = 2;
const AWS_SCA_SHA1: i32 = 3;
const AWS_SCA_SHA256: i32 = 4;

/// CRT checksum location enum values.
const AWS_SCL_NONE: i32 = 0;
#[allow(dead_code)]
const AWS_SCL_HEADER: i32 = 1;
const AWS_SCL_TRAILER: i32 = 2;

/// Mirrors `struct aws_s3_checksum_config` from aws-c-s3/s3_client.h.
///
/// Controls automatic checksum computation (for uploads) and validation
/// (for downloads).
#[repr(C)]
struct AwsS3ChecksumConfig {
    /// Where to put the computed checksum (header or trailer). PUT-specific.
    location: i32, // enum aws_s3_checksum_location
    /// The checksum algorithm to use. Must be set if location != NONE.
    checksum_algorithm: i32, // enum aws_s3_checksum_algorithm
    /// Optional callback for full-object checksum (experimental). We don't use it.
    full_object_checksum_callback: *const std::ffi::c_void,
    /// User data for the callback above.
    callback_user_data: *const std::ffi::c_void,
    /// GET-specific: whether to validate the response checksum.
    validate_response_checksum: bool,
    _pad0: [u8; 7],
    /// Optional pointer to aws_array_list of algorithms to validate. NULL = all.
    validate_checksum_algorithms: *const std::ffi::c_void,
}

/// Mirrors `struct aws_s3_meta_request_options` from aws-c-s3/s3_client.h.
///
/// This is a large struct with many fields. We define the layout to match
/// the C header exactly. Fields we don't use are zeroed.
#[repr(C)]
struct AwsS3MetaRequestOptions {
    // enum aws_s3_meta_request_type
    meta_request_type: i32,
    // 4 bytes padding to align aws_byte_cursor (8-byte aligned)
    _pad0: u32,
    // struct aws_byte_cursor operation_name
    operation_name: AwsByteCursor,
    // const struct aws_signing_config_aws *
    signing_config: *const AwsSigningConfigAws,
    // struct aws_http_message *
    message: *mut AwsHttpMessage,
    // struct aws_byte_cursor recv_filepath
    recv_filepath: AwsByteCursor,
    // enum aws_s3_recv_file_options
    recv_file_option: i32,
    // 4 bytes padding to align u64
    _pad1: u32,
    // uint64_t recv_file_position
    recv_file_position: u64,
    // bool recv_file_delete_on_failure
    recv_file_delete_on_failure: bool,
    // 7 bytes padding to align aws_byte_cursor
    _pad2: [u8; 7],
    // struct aws_byte_cursor send_filepath
    send_filepath: AwsByteCursor,
    // struct aws_s3_file_io_options *fio_opts
    fio_opts: *const std::ffi::c_void,
    // struct aws_async_input_stream *send_async_stream
    send_async_stream: *const std::ffi::c_void,
    // bool send_using_async_writes
    send_using_async_writes: bool,
    // 7 bytes padding to align pointer
    _pad3: [u8; 7],
    // const struct aws_s3_checksum_config *
    checksum_config: *const AwsS3ChecksumConfig,
    // uint64_t part_size
    part_size: u64,
    // bool force_dynamic_part_size
    force_dynamic_part_size: bool,
    // 7 bytes padding to align u64
    _pad4: [u8; 7],
    // uint64_t multipart_upload_threshold
    multipart_upload_threshold: u64,
    // void *user_data
    user_data: *mut std::ffi::c_void,
    // headers_callback
    headers_callback: Option<
        unsafe extern "C" fn(
            meta_request: *mut AwsS3MetaRequest,
            headers: *const AwsHttpHeaders,
            response_status: i32,
            user_data: *mut std::ffi::c_void,
        ) -> i32,
    >,
    // body_callback
    body_callback: Option<
        unsafe extern "C" fn(
            meta_request: *mut AwsS3MetaRequest,
            body: *const AwsByteCursor,
            range_start: u64,
            user_data: *mut std::ffi::c_void,
        ) -> i32,
    >,
    // body_callback_ex (not used)
    body_callback_ex: *const std::ffi::c_void,
    // finish_callback
    finish_callback: Option<
        unsafe extern "C" fn(
            meta_request: *mut AwsS3MetaRequest,
            result: *const AwsS3MetaRequestResult,
            user_data: *mut std::ffi::c_void,
        ),
    >,
    // shutdown_callback
    shutdown_callback: Option<
        unsafe extern "C" fn(user_data: *mut std::ffi::c_void),
    >,
    // progress_callback
    progress_callback: Option<
        unsafe extern "C" fn(
            meta_request: *mut AwsS3MetaRequest,
            progress: *const AwsS3MetaRequestProgress,
            user_data: *mut std::ffi::c_void,
        ),
    >,
    // telemetry_callback
    telemetry_callback: *const std::ffi::c_void,
    // upload_review_callback
    upload_review_callback: *const std::ffi::c_void,
    // const struct aws_uri *endpoint
    endpoint: *const std::ffi::c_void,
    // struct aws_s3_meta_request_resume_token *resume_token
    resume_token: *const std::ffi::c_void,
    // const uint64_t *object_size_hint
    object_size_hint: *const u64,
    // struct aws_byte_cursor copy_source_uri
    copy_source_uri: AwsByteCursor,
    // uint32_t max_active_connections_override
    max_active_connections_override: u32,
    // 4 bytes trailing padding (struct alignment)
    _pad5: u32,
}

/// Mirrors `struct aws_s3_meta_request_result` from aws-c-s3/s3_client.h.
///
/// Passed to the finish callback with the final result of the meta-request.
/// Field order matches the C header: error_response_headers, error_response_body,
/// error_response_operation_name, response_status, did_validate,
/// validation_algorithm, error_code.
#[repr(C)]
struct AwsS3MetaRequestResult {
    /// Headers from the error response (NULL if not an HTTP error).
    error_response_headers: *const AwsHttpHeaders,
    /// Body from the error response (NULL if not an HTTP error).
    error_response_body: *const AwsByteBuf,
    /// Operation name from the error response (NULL if not an HTTP error).
    error_response_operation_name: *const std::ffi::c_void, // aws_string *
    /// HTTP response status code.
    response_status: i32,
    /// Whether the server-side checksum was validated.
    did_validate: bool,
    /// 3 bytes padding to align enum (i32).
    _pad0: [u8; 3],
    /// Algorithm used to validate checksum.
    validation_algorithm: i32,
    /// Final CRT error code (0 = success).
    error_code: i32,
}

/// Mirrors `struct aws_s3_meta_request_progress`.
#[repr(C)]
struct AwsS3MetaRequestProgress {
    bytes_transferred: u64,
    content_length: u64,
}

/// Opaque CRT headers collection.
#[repr(C)]
struct AwsHttpHeaders {
    _opaque: [u8; 0],
}

/// Mirrors `struct aws_byte_buf` from aws-c-common.
#[repr(C)]
struct AwsByteBuf {
    len: usize,
    buffer: *const u8,
    capacity: usize,
    allocator: *mut AwsAllocator,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_default_allocator() -> *mut AwsAllocator;

    // HTTP message construction (same as http.rs)
    fn aws_http_message_new_request(
        allocator: *mut AwsAllocator,
    ) -> *mut AwsHttpMessage;
    fn aws_http_message_release(message: *mut AwsHttpMessage) -> *mut AwsHttpMessage;
    fn aws_http_message_set_request_method(
        message: *mut AwsHttpMessage,
        method: AwsByteCursor,
    ) -> i32;
    fn aws_http_message_set_request_path(
        message: *mut AwsHttpMessage,
        path: AwsByteCursor,
    ) -> i32;
    fn aws_http_message_add_header(
        message: *mut AwsHttpMessage,
        header: AwsHttpHeader,
    ) -> i32;
    fn aws_http_message_set_body_stream(
        message: *mut AwsHttpMessage,
        body_stream: *mut AwsInputStream,
    );

    // Input stream for request body
    fn aws_input_stream_new_from_cursor(
        allocator: *mut AwsAllocator,
        cursor: *const AwsByteCursor,
    ) -> *mut AwsInputStream;
    fn aws_input_stream_release(stream: *mut AwsInputStream);

    // S3 meta-request
    fn aws_s3_client_make_meta_request(
        client: *mut AwsS3Client,
        options: *const AwsS3MetaRequestOptions,
    ) -> *mut AwsS3MetaRequest;

    fn aws_s3_meta_request_release(
        meta_request: *mut AwsS3MetaRequest,
    ) -> *mut AwsS3MetaRequest;

    // HTTP headers iteration
    fn aws_http_headers_count(
        headers: *const AwsHttpHeaders,
    ) -> usize;
    fn aws_http_headers_get_index(
        headers: *const AwsHttpHeaders,
        index: usize,
        out_header: *mut AwsHttpHeader,
    ) -> i32;

    // Ruby GVL management
    fn rb_thread_call_without_gvl(
        func: unsafe extern "C" fn(
            data: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
        ubf: *const std::ffi::c_void,
        ubf_data: *const std::ffi::c_void,
    ) -> *mut std::ffi::c_void;

    // Checksum algorithm name lookup
    fn aws_get_checksum_algorithm_name(
        algorithm: i32,
    ) -> AwsByteCursor;
}

// ---------------------------------------------------------------------------
// Shared callback state
// ---------------------------------------------------------------------------

/// State shared between the Ruby thread (waiting for completion) and the
/// CRT event loop threads (firing callbacks). Protected by a Mutex + Condvar
/// so the Ruby thread can block (without the GVL) until the meta-request
/// completes.
struct MetaRequestState {
    /// HTTP response status code (set in headers_callback).
    status_code: i32,
    /// Collected response headers as (name, value) pairs.
    headers: Vec<(String, String)>,
    /// Accumulated response body bytes (buffered mode only).
    body: Vec<u8>,
    /// CRT error code from finish_callback (0 = success).
    error_code: i32,
    /// HTTP status from the error response (if any).
    error_response_status: i32,
    /// Headers from the error response (if any).
    error_response_headers: Vec<(String, String)>,
    /// Body from the error response (if any).
    error_response_body: Vec<u8>,
    /// Checksum algorithm name if the CRT validated the response checksum.
    checksum_validated: Option<String>,
    /// Total bytes transferred (updated by progress_callback).
    bytes_transferred: u64,
    /// Set to true when finish_callback fires.
    complete: bool,
}

// SAFETY: MetaRequestState is only accessed under the Mutex lock.
unsafe impl Send for MetaRequestState {}

type SharedState = Arc<(Mutex<MetaRequestState>, Condvar)>;

// ---------------------------------------------------------------------------
// CRT callbacks (run on CRT event loop threads)
// ---------------------------------------------------------------------------

/// Called once when response headers arrive.
///
/// Stores the status code and headers in shared state. The CRT passes an
/// opaque `aws_http_headers` collection, which we iterate using
/// `aws_http_headers_count` and `aws_http_headers_get_index`.
unsafe extern "C" fn headers_callback(
    _meta_request: *mut AwsS3MetaRequest,
    headers: *const AwsHttpHeaders,
    response_status: i32,
    user_data: *mut std::ffi::c_void,
) -> i32 {
    let state = &*(user_data as *const SharedState);
    let mut guard = state.0.lock().unwrap();

    guard.status_code = response_status;

    if !headers.is_null() {
        let count = aws_http_headers_count(headers);
        for i in 0..count {
            let mut header = AwsHttpHeader {
                name: AwsByteCursor { len: 0, ptr: std::ptr::null() },
                value: AwsByteCursor { len: 0, ptr: std::ptr::null() },
                compression: 0,
                _pad: 0,
            };
            if aws_http_headers_get_index(headers, i, &mut header) == 0 {
                let name = std::str::from_utf8_unchecked(
                    std::slice::from_raw_parts(header.name.ptr, header.name.len),
                )
                .to_string();
                let value = std::str::from_utf8_unchecked(
                    std::slice::from_raw_parts(header.value.ptr, header.value.len),
                )
                .to_string();
                guard.headers.push((name, value));
            }
        }
    }

    0 // AWS_OP_SUCCESS
}

/// Called per body chunk (only when not using recv_filepath).
///
/// In buffered mode, appends the chunk to the body buffer.
unsafe extern "C" fn body_callback(
    _meta_request: *mut AwsS3MetaRequest,
    body: *const AwsByteCursor,
    _range_start: u64,
    user_data: *mut std::ffi::c_void,
) -> i32 {
    let state = &*(user_data as *const SharedState);
    let cursor = &*body;
    let bytes = std::slice::from_raw_parts(cursor.ptr, cursor.len);

    let mut guard = state.0.lock().unwrap();
    guard.body.extend_from_slice(bytes);

    0 // AWS_OP_SUCCESS
}

/// Called once when the meta-request completes (success or failure).
///
/// Sets the error code, captures error response data if present, records
/// checksum validation status, and signals the condvar to wake the Ruby
/// thread.
unsafe extern "C" fn finish_callback(
    _meta_request: *mut AwsS3MetaRequest,
    result: *const AwsS3MetaRequestResult,
    user_data: *mut std::ffi::c_void,
) {
    let state = &*(user_data as *const SharedState);
    let r = &*result;

    let mut guard = state.0.lock().unwrap();
    guard.error_code = r.error_code;

    // Capture error response data if present
    if r.response_status >= 400 {
        guard.error_response_status = r.response_status;

        // Extract error response headers
        if !r.error_response_headers.is_null() {
            let count = aws_http_headers_count(r.error_response_headers);
            for i in 0..count {
                let mut header = AwsHttpHeader {
                    name: AwsByteCursor { len: 0, ptr: std::ptr::null() },
                    value: AwsByteCursor { len: 0, ptr: std::ptr::null() },
                    compression: 0,
                    _pad: 0,
                };
                if aws_http_headers_get_index(
                    r.error_response_headers,
                    i,
                    &mut header,
                ) == 0
                {
                    let name = std::str::from_utf8_unchecked(
                        std::slice::from_raw_parts(header.name.ptr, header.name.len),
                    )
                    .to_string();
                    let value = std::str::from_utf8_unchecked(
                        std::slice::from_raw_parts(header.value.ptr, header.value.len),
                    )
                    .to_string();
                    guard.error_response_headers.push((name, value));
                }
            }
        }

        // Extract error response body
        if !r.error_response_body.is_null() {
            let buf = &*r.error_response_body;
            if !buf.buffer.is_null() && buf.len > 0 {
                let bytes = std::slice::from_raw_parts(buf.buffer, buf.len);
                guard.error_response_body = bytes.to_vec();
            }
        }
    }

    // Record checksum validation status
    if r.did_validate && r.validation_algorithm != AWS_SCA_NONE {
        let algo_cursor = aws_get_checksum_algorithm_name(r.validation_algorithm);
        if !algo_cursor.ptr.is_null() && algo_cursor.len > 0 {
            let algo_bytes =
                std::slice::from_raw_parts(algo_cursor.ptr, algo_cursor.len);
            if let Ok(algo_str) = std::str::from_utf8(algo_bytes) {
                guard.checksum_validated = Some(algo_str.to_string());
            }
        }
    }

    guard.complete = true;
    state.1.notify_one();
}

/// Called with progress updates (bytes transferred).
unsafe extern "C" fn progress_callback(
    _meta_request: *mut AwsS3MetaRequest,
    progress: *const AwsS3MetaRequestProgress,
    user_data: *mut std::ffi::c_void,
) {
    let state = &*(user_data as *const SharedState);
    let p = &*progress;

    let mut guard = state.0.lock().unwrap();
    guard.bytes_transferred += p.bytes_transferred;
}

// ---------------------------------------------------------------------------
// GVL release wrapper
// ---------------------------------------------------------------------------

/// Data passed to the without-GVL function.
struct WaitData {
    state: SharedState,
}

/// Called without the GVL — blocks on the condvar until the meta-request
/// completes. Same pattern as `http.rs`.
unsafe extern "C" fn wait_for_completion(
    data: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
    let wait_data = &*(data as *const WaitData);
    let (lock, cvar) = &*wait_data.state;

    let mut guard = lock.lock().unwrap();
    while !guard.complete {
        guard = cvar.wait(guard).unwrap();
    }

    std::ptr::null_mut()
}

// ---------------------------------------------------------------------------
// Response type
// ---------------------------------------------------------------------------

/// The result of an S3 meta-request.
pub struct S3Response {
    pub status_code: i32,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub checksum_validated: Option<String>,
}

/// Error data from a failed S3 meta-request.
pub struct S3ErrorData {
    /// CRT error code (0 means the error is an HTTP error, not a CRT error).
    pub error_code: i32,
    /// HTTP status code from the error response.
    pub status_code: i32,
    /// Headers from the error response.
    pub headers: Vec<(String, String)>,
    /// Body from the error response (typically S3 XML error).
    pub body: Vec<u8>,
}

/// Result type for S3 operations — either a successful response or error data.
pub type S3Result = Result<S3Response, S3ErrorData>;

// ---------------------------------------------------------------------------
// HTTP request message builder
// ---------------------------------------------------------------------------

/// Build a CRT HTTP request message for an S3 operation.
///
/// Sets the method, path (/<key>), and Host header using the virtual-hosted
/// style endpoint: `<bucket>.s3.<region>.amazonaws.com`.
fn build_s3_request_message(
    method: &str,
    bucket: &str,
    key: &str,
    region: &str,
    extra_headers: &[(String, String)],
) -> Result<*mut AwsHttpMessage, CrtError> {
    let allocator = unsafe { aws_default_allocator() };

    let request = unsafe { aws_http_message_new_request(allocator) };
    if request.is_null() {
        return Err(CrtError::last_error());
    }

    // Set method
    let method_cursor = AwsByteCursor::from_str(method);
    if unsafe { aws_http_message_set_request_method(request, method_cursor) } != 0 {
        unsafe { aws_http_message_release(request) };
        return Err(CrtError::last_error());
    }

    // Set path — must start with /
    let path = if key.starts_with('/') {
        format!("{}", key)
    } else {
        format!("/{}", key)
    };
    let path_cursor = AwsByteCursor::from_str(&path);
    if unsafe { aws_http_message_set_request_path(request, path_cursor) } != 0 {
        unsafe { aws_http_message_release(request) };
        return Err(CrtError::last_error());
    }

    // Set Host header — virtual-hosted style
    let host = format!("{}.s3.{}.amazonaws.com", bucket, region);
    let host_header = AwsHttpHeader {
        name: AwsByteCursor::from_str("Host"),
        value: AwsByteCursor::from_str(&host),
        compression: 0,
        _pad: 0,
    };
    if unsafe { aws_http_message_add_header(request, host_header) } != 0 {
        unsafe { aws_http_message_release(request) };
        return Err(CrtError::last_error());
    }

    // Add extra headers (Content-Type, Content-Length, etc.)
    for (name, value) in extra_headers {
        let header = AwsHttpHeader {
            name: AwsByteCursor::from_str(name),
            value: AwsByteCursor::from_str(value),
            compression: 0,
            _pad: 0,
        };
        if unsafe { aws_http_message_add_header(request, header) } != 0 {
            unsafe { aws_http_message_release(request) };
            return Err(CrtError::last_error());
        }
    }

    Ok(request)
}

// ---------------------------------------------------------------------------
// Checksum configuration helper
// ---------------------------------------------------------------------------

/// Parse a checksum algorithm name to the CRT enum value.
///
/// Returns `Ok(algorithm_value)` for valid names, or `Err` for invalid ones.
pub fn parse_checksum_algorithm(name: &str) -> Result<i32, CrtError> {
    match name {
        "CRC32" => Ok(AWS_SCA_CRC32),
        "CRC32C" => Ok(AWS_SCA_CRC32C),
        "SHA1" => Ok(AWS_SCA_SHA1),
        "SHA256" => Ok(AWS_SCA_SHA256),
        _ => Err(CrtError::from_code(0)), // Invalid algorithm
    }
}

// ---------------------------------------------------------------------------
// Meta-request execution helpers
// ---------------------------------------------------------------------------

/// Create shared state for a meta-request.
fn new_shared_state() -> SharedState {
    Arc::new((
        Mutex::new(MetaRequestState {
            status_code: 0,
            headers: Vec::new(),
            body: Vec::new(),
            error_code: 0,
            error_response_status: 0,
            error_response_headers: Vec::new(),
            error_response_body: Vec::new(),
            checksum_validated: None,
            bytes_transferred: 0,
            complete: false,
        }),
        Condvar::new(),
    ))
}

/// Extract the result from shared state after the meta-request completes.
///
/// Returns `Ok(S3Response)` on success, or `Err(S3ErrorData)` on failure.
fn extract_result(state: &SharedState, include_body: bool) -> S3Result {
    let mut guard = state.0.lock().unwrap();

    // Check for CRT-level errors (network failures, etc.)
    if guard.error_code != 0 {
        return Err(S3ErrorData {
            error_code: guard.error_code,
            status_code: guard.error_response_status,
            headers: std::mem::take(&mut guard.error_response_headers),
            body: std::mem::take(&mut guard.error_response_body),
        });
    }

    // Check for HTTP error responses (4xx, 5xx)
    if guard.error_response_status >= 400 {
        return Err(S3ErrorData {
            error_code: 0,
            status_code: guard.error_response_status,
            headers: std::mem::take(&mut guard.error_response_headers),
            body: std::mem::take(&mut guard.error_response_body),
        });
    }

    let body = if include_body {
        let b = std::mem::take(&mut guard.body);
        if b.is_empty() { None } else { Some(b) }
    } else {
        None
    };

    Ok(S3Response {
        status_code: guard.status_code,
        headers: std::mem::take(&mut guard.headers),
        body,
        checksum_validated: guard.checksum_validated.take(),
    })
}

// ---------------------------------------------------------------------------
// Public API: get_object
// ---------------------------------------------------------------------------

/// Options for a GET_OBJECT meta-request.
pub struct GetObjectOptions<'a> {
    pub client: *mut AwsS3Client,
    pub signing_config: *const AwsSigningConfigAws,
    pub bucket: &'a str,
    pub key: &'a str,
    pub region: &'a str,
    /// If set, CRT writes directly to this file path (recv_filepath mode).
    pub recv_filepath: Option<&'a str>,
    /// Whether to validate the response checksum.
    pub validate_checksum: bool,
}

/// Execute a GET_OBJECT meta-request.
///
/// Builds the HTTP request, configures the meta-request with the appropriate
/// body handling mode, releases the GVL during the blocking wait, and returns
/// the response.
///
/// When `recv_filepath` is set, the CRT writes the response body directly to
/// the file using parallel I/O — no body data passes through Rust or Ruby.
/// Otherwise, the body is buffered in memory via `body_callback`.
pub fn get_object(options: GetObjectOptions) -> S3Result {
    let request = build_s3_request_message(
        "GET",
        options.bucket,
        options.key,
        options.region,
        &[],
    )
    .map_err(|e| S3ErrorData {
        error_code: -1,
        status_code: 0,
        headers: Vec::new(),
        body: e.to_string().into_bytes(),
    })?;

    let state = new_shared_state();

    // Build checksum config for validation if requested
    let checksum_config = if options.validate_checksum {
        Some(AwsS3ChecksumConfig {
            location: AWS_SCL_NONE,
            checksum_algorithm: AWS_SCA_NONE,
            full_object_checksum_callback: std::ptr::null(),
            callback_user_data: std::ptr::null(),
            validate_response_checksum: true,
            _pad0: [0; 7],
            // NULL = validate all supported algorithms (CRT default)
            validate_checksum_algorithms: std::ptr::null(),
        })
    } else {
        None
    };

    // Build recv_filepath CString if provided (must outlive the options struct)
    let recv_filepath_c = options
        .recv_filepath
        .map(|p| CString::new(p).expect("recv_filepath contains null byte"));

    let recv_filepath_cursor = recv_filepath_c
        .as_ref()
        .map(|c| AwsByteCursor {
            len: c.as_bytes().len(),
            ptr: c.as_ptr() as *const u8,
        })
        .unwrap_or_else(|| AwsByteCursor { len: 0, ptr: std::ptr::null() });

    let use_recv_filepath = options.recv_filepath.is_some();

    let meta_request_options = AwsS3MetaRequestOptions {
        meta_request_type: AWS_S3_META_REQUEST_TYPE_GET_OBJECT,
        _pad0: 0,
        operation_name: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        signing_config: options.signing_config,
        message: request,
        recv_filepath: recv_filepath_cursor,
        recv_file_option: 0, // AWS_S3_RECV_FILE_CREATE_OR_REPLACE
        _pad1: 0,
        recv_file_position: 0,
        recv_file_delete_on_failure: false,
        _pad2: [0; 7],
        send_filepath: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        fio_opts: std::ptr::null(),
        send_async_stream: std::ptr::null(),
        send_using_async_writes: false,
        _pad3: [0; 7],
        checksum_config: checksum_config
            .as_ref()
            .map(|c| c as *const AwsS3ChecksumConfig)
            .unwrap_or(std::ptr::null()),
        part_size: 0,
        force_dynamic_part_size: false,
        _pad4: [0; 7],
        multipart_upload_threshold: 0,
        user_data: &state as *const SharedState as *mut std::ffi::c_void,
        headers_callback: Some(headers_callback),
        // No body callback when using recv_filepath — CRT writes directly to file
        body_callback: if use_recv_filepath { None } else { Some(body_callback) },
        body_callback_ex: std::ptr::null(),
        finish_callback: Some(finish_callback),
        shutdown_callback: None,
        progress_callback: Some(progress_callback),
        telemetry_callback: std::ptr::null(),
        upload_review_callback: std::ptr::null(),
        endpoint: std::ptr::null(),
        resume_token: std::ptr::null(),
        object_size_hint: std::ptr::null(),
        copy_source_uri: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        max_active_connections_override: 0,
        _pad5: 0,
    };

    let meta_request = unsafe {
        aws_s3_client_make_meta_request(options.client, &meta_request_options)
    };

    if meta_request.is_null() {
        unsafe { aws_http_message_release(request) };
        let err = CrtError::last_error();
        return Err(S3ErrorData {
            error_code: -1,
            status_code: 0,
            headers: Vec::new(),
            body: err.to_string().into_bytes(),
        });
    }

    // Release the GVL and wait for completion
    let wait_data = WaitData {
        state: Arc::clone(&state),
    };
    unsafe {
        rb_thread_call_without_gvl(
            wait_for_completion,
            &wait_data as *const WaitData as *mut std::ffi::c_void,
            std::ptr::null(),
            std::ptr::null(),
        );
    }

    // Clean up CRT resources
    unsafe {
        aws_s3_meta_request_release(meta_request);
        aws_http_message_release(request);
    }

    // Extract result — include body only when not using recv_filepath
    extract_result(&state, !use_recv_filepath)
}

// ---------------------------------------------------------------------------
// Public API: put_object
// ---------------------------------------------------------------------------

/// Options for a PUT_OBJECT meta-request.
pub struct PutObjectOptions<'a> {
    pub client: *mut AwsS3Client,
    pub signing_config: *const AwsSigningConfigAws,
    pub bucket: &'a str,
    pub key: &'a str,
    pub region: &'a str,
    /// If set, CRT reads directly from this file path (send_filepath mode).
    pub send_filepath: Option<&'a str>,
    /// In-memory body bytes (used when send_filepath is None).
    pub body: Option<Vec<u8>>,
    /// Content-Length header value (optional).
    pub content_length: Option<u64>,
    /// Content-Type header value (optional).
    pub content_type: Option<&'a str>,
    /// Checksum algorithm to compute (CRC32, CRC32C, SHA1, SHA256).
    pub checksum_algorithm: Option<i32>,
}

/// Execute a PUT_OBJECT meta-request.
///
/// Builds the HTTP request, configures the meta-request with the appropriate
/// body source mode, releases the GVL during the blocking wait, and returns
/// the response.
///
/// When `send_filepath` is set, the CRT reads the file directly using
/// parallel I/O — no body data passes through Rust or Ruby. Otherwise,
/// the body bytes are passed to the CRT via an input stream.
pub fn put_object(options: PutObjectOptions) -> S3Result {
    // Build extra headers
    let mut extra_headers: Vec<(String, String)> = Vec::new();
    if let Some(ct) = options.content_type {
        extra_headers.push(("Content-Type".to_string(), ct.to_string()));
    }
    if let Some(cl) = options.content_length {
        extra_headers.push(("Content-Length".to_string(), cl.to_string()));
    }

    let request = build_s3_request_message(
        "PUT",
        options.bucket,
        options.key,
        options.region,
        &extra_headers,
    )
    .map_err(|e| S3ErrorData {
        error_code: -1,
        status_code: 0,
        headers: Vec::new(),
        body: e.to_string().into_bytes(),
    })?;

    // Set up body stream if we have in-memory body data (not send_filepath).
    // The body_data Vec must outlive the input stream — aws_input_stream_new_from_cursor
    // copies the cursor struct but NOT the underlying bytes.
    let (body_stream, _body_data) = if options.send_filepath.is_none() {
        if let Some(data) = options.body {
            if !data.is_empty() {
                let cursor = AwsByteCursor {
                    len: data.len(),
                    ptr: data.as_ptr(),
                };
                let stream = unsafe {
                    aws_input_stream_new_from_cursor(
                        aws_default_allocator(),
                        &cursor,
                    )
                };
                if stream.is_null() {
                    unsafe { aws_http_message_release(request) };
                    let err = CrtError::last_error();
                    return Err(S3ErrorData {
                        error_code: -1,
                        status_code: 0,
                        headers: Vec::new(),
                        body: err.to_string().into_bytes(),
                    });
                }
                unsafe { aws_http_message_set_body_stream(request, stream) };
                (stream, Some(data))
            } else {
                (std::ptr::null_mut(), None)
            }
        } else {
            (std::ptr::null_mut(), None)
        }
    } else {
        (std::ptr::null_mut(), None)
    };

    let state = new_shared_state();

    // Build checksum config if an algorithm was specified
    let checksum_config = options.checksum_algorithm.map(|algo| AwsS3ChecksumConfig {
        location: AWS_SCL_TRAILER,
        checksum_algorithm: algo,
        full_object_checksum_callback: std::ptr::null(),
        callback_user_data: std::ptr::null(),
        validate_response_checksum: false,
        _pad0: [0; 7],
        validate_checksum_algorithms: std::ptr::null(),
    });

    // Build send_filepath CString if provided (must outlive the options struct)
    let send_filepath_c = options
        .send_filepath
        .map(|p| CString::new(p).expect("send_filepath contains null byte"));

    let send_filepath_cursor = send_filepath_c
        .as_ref()
        .map(|c| AwsByteCursor {
            len: c.as_bytes().len(),
            ptr: c.as_ptr() as *const u8,
        })
        .unwrap_or_else(|| AwsByteCursor { len: 0, ptr: std::ptr::null() });

    let meta_request_options = AwsS3MetaRequestOptions {
        meta_request_type: AWS_S3_META_REQUEST_TYPE_PUT_OBJECT,
        _pad0: 0,
        operation_name: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        signing_config: options.signing_config,
        message: request,
        recv_filepath: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        recv_file_option: 0,
        _pad1: 0,
        recv_file_position: 0,
        recv_file_delete_on_failure: false,
        _pad2: [0; 7],
        send_filepath: send_filepath_cursor,
        fio_opts: std::ptr::null(),
        send_async_stream: std::ptr::null(),
        send_using_async_writes: false,
        _pad3: [0; 7],
        checksum_config: checksum_config
            .as_ref()
            .map(|c| c as *const AwsS3ChecksumConfig)
            .unwrap_or(std::ptr::null()),
        part_size: 0,
        force_dynamic_part_size: false,
        _pad4: [0; 7],
        multipart_upload_threshold: 0,
        user_data: &state as *const SharedState as *mut std::ffi::c_void,
        headers_callback: Some(headers_callback),
        body_callback: None, // PUT responses don't have meaningful bodies
        body_callback_ex: std::ptr::null(),
        finish_callback: Some(finish_callback),
        shutdown_callback: None,
        progress_callback: Some(progress_callback),
        telemetry_callback: std::ptr::null(),
        upload_review_callback: std::ptr::null(),
        endpoint: std::ptr::null(),
        resume_token: std::ptr::null(),
        object_size_hint: std::ptr::null(),
        copy_source_uri: AwsByteCursor { len: 0, ptr: std::ptr::null() },
        max_active_connections_override: 0,
        _pad5: 0,
    };

    let meta_request = unsafe {
        aws_s3_client_make_meta_request(options.client, &meta_request_options)
    };

    if meta_request.is_null() {
        unsafe {
            if !body_stream.is_null() {
                aws_input_stream_release(body_stream);
            }
            aws_http_message_release(request);
        }
        let err = CrtError::last_error();
        return Err(S3ErrorData {
            error_code: -1,
            status_code: 0,
            headers: Vec::new(),
            body: err.to_string().into_bytes(),
        });
    }

    // Release the GVL and wait for completion
    let wait_data = WaitData {
        state: Arc::clone(&state),
    };
    unsafe {
        rb_thread_call_without_gvl(
            wait_for_completion,
            &wait_data as *const WaitData as *mut std::ffi::c_void,
            std::ptr::null(),
            std::ptr::null(),
        );
    }

    // Clean up CRT resources
    unsafe {
        aws_s3_meta_request_release(meta_request);
        if !body_stream.is_null() {
            aws_input_stream_release(body_stream);
        }
        aws_http_message_release(request);
    }
    // _body_data is dropped here, which is safe because the input stream
    // has already been released above.

    // PUT responses don't include a body
    extract_result(&state, false)
}
