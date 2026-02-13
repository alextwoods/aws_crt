//! HTTP request/response bridge between Ruby and CRT.
//!
//! Provides `make_request()` (buffered) and `make_streaming_request()` (chunked)
//! which acquire a connection from a connection manager, send an HTTP request,
//! collect the response via CRT callbacks, and return the result to Ruby.
//!
//! The GVL is released during blocking waits so other Ruby threads can run.
//! Body data is copied into Rust-owned memory before the GVL is released to
//! prevent use-after-free if Ruby's GC moves the original string.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};

use crate::connection_manager::{AwsHttpConnection, AwsHttpConnectionManager};
use crate::error::CrtError;
use crate::runtime::AwsAllocator;

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

#[repr(C)]
struct AwsHttpMessage {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AwsHttpStream {
    _opaque: [u8; 0],
}

#[repr(C)]
struct AwsInputStream {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// FFI struct mirrors
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_byte_cursor`.
#[repr(C)]
#[derive(Clone, Copy)]
struct AwsByteCursor {
    len: usize,
    ptr: *const u8,
}

impl AwsByteCursor {
    fn from_slice(s: &[u8]) -> Self {
        Self {
            len: s.len(),
            ptr: s.as_ptr(),
        }
    }
}

/// Mirrors `struct aws_http_header`.
#[repr(C)]
struct AwsHttpHeader {
    name: AwsByteCursor,
    value: AwsByteCursor,
    compression: u32, // enum aws_http_header_compression
    _pad: u32,
}

/// Mirrors `struct aws_http_make_request_options`.
#[repr(C)]
struct AwsHttpMakeRequestOptions {
    self_size: usize,
    request: *mut AwsHttpMessage,
    user_data: *mut std::ffi::c_void,
    on_response_headers: Option<
        unsafe extern "C" fn(
            stream: *mut AwsHttpStream,
            header_block: u32,
            header_array: *const AwsHttpHeader,
            num_headers: usize,
            user_data: *mut std::ffi::c_void,
        ) -> i32,
    >,
    on_response_header_block_done: Option<
        unsafe extern "C" fn(
            stream: *mut AwsHttpStream,
            header_block: u32,
            user_data: *mut std::ffi::c_void,
        ) -> i32,
    >,
    on_response_body: Option<
        unsafe extern "C" fn(
            stream: *mut AwsHttpStream,
            data: *const AwsByteCursor,
            user_data: *mut std::ffi::c_void,
        ) -> i32,
    >,
    on_metrics: *const std::ffi::c_void,
    on_complete: Option<
        unsafe extern "C" fn(
            stream: *mut AwsHttpStream,
            error_code: i32,
            user_data: *mut std::ffi::c_void,
        ),
    >,
    on_destroy: *const std::ffi::c_void,
    http2_use_manual_data_writes: bool,
    _pad0: [u8; 7],
    response_first_byte_timeout_ms: u64,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_default_allocator() -> *mut AwsAllocator;

    // HTTP message construction
    fn aws_http_message_new_request(
        allocator: *mut AwsAllocator,
    ) -> *mut AwsHttpMessage;
    fn aws_http_message_release(
        message: *mut AwsHttpMessage,
    ) -> *mut AwsHttpMessage;
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

    // Connection manager
    fn aws_http_connection_manager_acquire_connection(
        manager: *mut AwsHttpConnectionManager,
        callback: unsafe extern "C" fn(
            connection: *mut AwsHttpConnection,
            error_code: i32,
            user_data: *mut std::ffi::c_void,
        ),
        user_data: *mut std::ffi::c_void,
    );
    fn aws_http_connection_manager_release_connection(
        manager: *mut AwsHttpConnectionManager,
        connection: *mut AwsHttpConnection,
    ) -> i32;

    // HTTP stream (request/response)
    fn aws_http_connection_make_request(
        connection: *mut AwsHttpConnection,
        options: *const AwsHttpMakeRequestOptions,
    ) -> *mut AwsHttpStream;
    fn aws_http_stream_activate(stream: *mut AwsHttpStream) -> i32;
    fn aws_http_stream_release(stream: *mut AwsHttpStream);
    fn aws_http_stream_get_incoming_response_status(
        stream: *const AwsHttpStream,
        out_status: *mut i32,
    ) -> i32;

    // CRT error
    fn aws_last_error() -> i32;

    // Ruby GVL management
    fn rb_thread_call_without_gvl(
        func: unsafe extern "C" fn(
            data: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
        ubf: *const std::ffi::c_void,
        ubf_data: *const std::ffi::c_void,
    ) -> *mut std::ffi::c_void;
}

// ---------------------------------------------------------------------------
// Shared callback state
// ---------------------------------------------------------------------------

/// State shared between the main thread (waiting for the response) and the
/// CRT event loop thread (firing callbacks). Protected by a Mutex + Condvar
/// so the main thread can block (without the GVL) until data is ready.
struct RequestState {
    /// Response status code (set in on_response_headers).
    status_code: i32,
    /// Collected response headers as (name, value) pairs.
    headers: Vec<(String, String)>,
    /// Accumulated response body bytes (buffered mode only).
    body: Vec<u8>,
    /// Queue of body chunks for streaming mode. Each chunk is yielded to
    /// the Ruby block individually.
    chunks: VecDeque<Vec<u8>>,
    /// Whether this request uses streaming mode.
    streaming: bool,
    /// CRT error code from on_complete (0 = success).
    error_code: i32,
    /// Set to true when on_complete fires.
    complete: bool,
    /// The acquired connection (needed for release after request).
    connection: *mut AwsHttpConnection,
    /// The connection manager (needed for releasing the connection).
    manager: *mut AwsHttpConnectionManager,
}

// SAFETY: RequestState is only accessed under the Mutex lock, and the raw
// pointers (connection, manager) are CRT objects that are thread-safe.
unsafe impl Send for RequestState {}

type SharedState = Arc<(Mutex<RequestState>, Condvar)>;

// ---------------------------------------------------------------------------
// CRT callbacks (run on the CRT event loop thread)
// ---------------------------------------------------------------------------

/// Called as response headers arrive.
unsafe extern "C" fn on_response_headers(
    stream: *mut AwsHttpStream,
    _header_block: u32,
    header_array: *const AwsHttpHeader,
    num_headers: usize,
    user_data: *mut std::ffi::c_void,
) -> i32 {
    let ctx = &*(user_data as *const RequestContext);
    let state = &ctx.state;

    let mut guard = state.0.lock().unwrap();

    // Get the status code on first header callback
    if guard.status_code == 0 {
        let mut status = 0i32;
        aws_http_stream_get_incoming_response_status(stream, &mut status);
        guard.status_code = status;
    }

    // Collect headers and look for Content-Length to pre-allocate body buffer
    let headers = std::slice::from_raw_parts(header_array, num_headers);
    for h in headers {
        let name_bytes =
            std::slice::from_raw_parts(h.name.ptr, h.name.len);
        let value_bytes =
            std::slice::from_raw_parts(h.value.ptr, h.value.len);

        // Pre-allocate body buffer from Content-Length (buffered mode only).
        // This avoids repeated Vec reallocations during on_response_body.
        if !guard.streaming && h.name.len == 14 {
            if name_bytes.eq_ignore_ascii_case(b"content-length") {
                if let Ok(s) = std::str::from_utf8(value_bytes) {
                    if let Ok(len) = s.parse::<usize>() {
                        guard.body.reserve(len);
                    }
                }
            }
        }

        let name =
            std::str::from_utf8_unchecked(name_bytes).to_string();
        let value =
            std::str::from_utf8_unchecked(value_bytes).to_string();
        guard.headers.push((name, value));
    }

    0 // AWS_OP_SUCCESS
}

/// Called as response body chunks arrive.
unsafe extern "C" fn on_response_body(
    _stream: *mut AwsHttpStream,
    data: *const AwsByteCursor,
    user_data: *mut std::ffi::c_void,
) -> i32 {
    let ctx = &*(user_data as *const RequestContext);
    let state = &ctx.state;

    let cursor = &*data;
    let bytes = std::slice::from_raw_parts(cursor.ptr, cursor.len);

    let mut guard = state.0.lock().unwrap();
    if guard.streaming {
        // Streaming mode: push chunk and notify the waiting Ruby thread
        guard.chunks.push_back(bytes.to_vec());
        state.1.notify_one();
    } else {
        // Buffered mode: accumulate into a single body buffer
        guard.body.extend_from_slice(bytes);
    }

    0 // AWS_OP_SUCCESS
}

/// Called when the request/response exchange is complete.
unsafe extern "C" fn on_stream_complete(
    stream: *mut AwsHttpStream,
    error_code: i32,
    user_data: *mut std::ffi::c_void,
) {
    let ctx = &*(user_data as *const RequestContext);
    let state = &ctx.state;

    // Release the stream
    aws_http_stream_release(stream);

    // Release the connection back to the pool
    let guard = state.0.lock().unwrap();
    let connection = guard.connection;
    let manager = guard.manager;
    drop(guard);

    if !connection.is_null() {
        aws_http_connection_manager_release_connection(manager, connection);
    }

    // Signal completion
    let mut guard = state.0.lock().unwrap();
    guard.error_code = error_code;
    guard.complete = true;
    state.1.notify_one();
}

// ---------------------------------------------------------------------------
// RequestContext — holds everything needed for the async request flow
// ---------------------------------------------------------------------------

/// Bundles the shared state with the pre-built request message and owned body
/// data so that the connection-acquired callback can fire off the HTTP request.
///
/// The `body_data` field is critical: `aws_input_stream_new_from_cursor` does
/// NOT copy the underlying bytes — it only stores the pointer. We must own the
/// body bytes here so they remain valid for the entire request lifetime,
/// including after the Ruby GVL is released (when Ruby's GC could otherwise
/// move or collect the original Ruby string).
struct RequestContext {
    state: SharedState,
    /// The pre-built HTTP request message. Owned by this context.
    request: *mut AwsHttpMessage,
    /// Body stream (if any). Must outlive the request.
    body_stream: *mut AwsInputStream,
    /// Owned copy of the request body bytes. The `body_stream` cursor points
    /// into this Vec, so it must not be dropped or reallocated before the
    /// stream is released.
    _body_data: Option<Vec<u8>>,
    /// Read timeout in milliseconds (0 = no timeout).
    response_first_byte_timeout_ms: u64,
}

// SAFETY: The CRT objects are thread-safe, and the RequestContext is only
// accessed from the CRT event loop thread after being passed as user_data.
unsafe impl Send for RequestContext {}
unsafe impl Sync for RequestContext {}

/// Connection-acquired callback that actually sends the request.
unsafe extern "C" fn on_connection_acquired_with_ctx(
    connection: *mut AwsHttpConnection,
    error_code: i32,
    user_data: *mut std::ffi::c_void,
) {
    let ctx = &*(user_data as *const RequestContext);
    let state = &ctx.state;

    if error_code != 0 || connection.is_null() {
        let mut guard = state.0.lock().unwrap();
        guard.error_code = if error_code != 0 { error_code } else { -1 };
        guard.complete = true;
        state.1.notify_one();
        return;
    }

    // Store the connection
    {
        let mut guard = state.0.lock().unwrap();
        guard.connection = connection;
    }

    // Set up the make_request options
    let request_options = AwsHttpMakeRequestOptions {
        self_size: std::mem::size_of::<AwsHttpMakeRequestOptions>(),
        request: ctx.request,
        user_data,
        on_response_headers: Some(on_response_headers),
        on_response_header_block_done: None,
        on_response_body: Some(on_response_body),
        on_metrics: std::ptr::null(),
        on_complete: Some(on_stream_complete),
        on_destroy: std::ptr::null(),
        http2_use_manual_data_writes: false,
        _pad0: [0; 7],
        response_first_byte_timeout_ms: ctx.response_first_byte_timeout_ms,
    };

    let stream =
        aws_http_connection_make_request(connection, &request_options);
    if stream.is_null() {
        // Failed to create stream — release connection and signal error
        let err = aws_last_error();
        aws_http_connection_manager_release_connection(
            state.0.lock().unwrap().manager,
            connection,
        );
        let mut guard = state.0.lock().unwrap();
        guard.error_code = if err != 0 { err } else { -1 };
        guard.complete = true;
        state.1.notify_one();
        return;
    }

    // Activate the stream to start sending
    let rc = aws_http_stream_activate(stream);
    if rc != 0 {
        let err = aws_last_error();
        aws_http_stream_release(stream);
        aws_http_connection_manager_release_connection(
            state.0.lock().unwrap().manager,
            connection,
        );
        let mut guard = state.0.lock().unwrap();
        guard.error_code = if err != 0 { err } else { -1 };
        guard.complete = true;
        state.1.notify_one();
    }
}

// ---------------------------------------------------------------------------
// GVL release wrappers
// ---------------------------------------------------------------------------

/// Data passed to the without-GVL function for buffered requests.
struct WaitData {
    state: SharedState,
}

/// Called without the GVL — blocks on the condvar until the request completes.
/// Used for buffered (non-streaming) requests.
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

/// Called without the GVL — blocks until either a body chunk arrives or the
/// request completes. Used for streaming requests. Returns as soon as there
/// is something for the Ruby thread to process.
unsafe extern "C" fn wait_for_chunk_or_completion(
    data: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
    let wait_data = &*(data as *const WaitData);
    let (lock, cvar) = &*wait_data.state;

    let mut guard = lock.lock().unwrap();
    while !guard.complete && guard.chunks.is_empty() {
        guard = cvar.wait(guard).unwrap();
    }

    std::ptr::null_mut()
}

// ---------------------------------------------------------------------------
// Request building helper
// ---------------------------------------------------------------------------

/// Options for building and executing an HTTP request.
pub struct RequestOptions<'a> {
    pub manager: *mut AwsHttpConnectionManager,
    pub method: &'a str,
    pub path: &'a str,
    pub headers: &'a [(String, String)],
    /// Owned body bytes. Passed by value to avoid a redundant copy —
    /// the Vec is moved directly into the `RequestContext` where it
    /// must remain alive for the CRT input stream's cursor.
    pub body: Option<Vec<u8>>,
    pub streaming: bool,
    /// Read timeout in milliseconds. If non-zero, the CRT will fail the
    /// request with `AWS_ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT` if the
    /// server does not begin responding within this duration after the
    /// request is fully sent.
    pub read_timeout_ms: u64,
}

/// Build a CRT request message and set up the shared state for async
/// execution. Returns the `RequestContext` (heap-allocated, caller must
/// eventually `Box::from_raw` it) and a clone of the shared state.
///
/// Body bytes are moved (not copied) into the `RequestContext`. The CRT
/// input stream's cursor points into this owned Vec, ensuring the data
/// remains valid after the GVL is released.
fn build_request(
    opts: RequestOptions,
) -> Result<(*mut RequestContext, SharedState), CrtError> {
    let allocator = unsafe { aws_default_allocator() };

    // Build the CRT request message
    let request = unsafe { aws_http_message_new_request(allocator) };
    if request.is_null() {
        return Err(CrtError::last_error());
    }

    // Set method and path
    let method_cursor = AwsByteCursor::from_slice(opts.method.as_bytes());
    let path_cursor = AwsByteCursor::from_slice(opts.path.as_bytes());

    unsafe {
        if aws_http_message_set_request_method(request, method_cursor) != 0 {
            aws_http_message_release(request);
            return Err(CrtError::last_error());
        }
        if aws_http_message_set_request_path(request, path_cursor) != 0 {
            aws_http_message_release(request);
            return Err(CrtError::last_error());
        }
    }

    // Add headers
    for (name, value) in opts.headers {
        let header = AwsHttpHeader {
            name: AwsByteCursor::from_slice(name.as_bytes()),
            value: AwsByteCursor::from_slice(value.as_bytes()),
            compression: 0, // AWS_HTTP_HEADER_COMPRESSION_USE_CACHE
            _pad: 0,
        };
        unsafe {
            if aws_http_message_add_header(request, header) != 0 {
                aws_http_message_release(request);
                return Err(CrtError::last_error());
            }
        }
    }

    // Move body bytes into owned storage and create the input stream.
    //
    // IMPORTANT: aws_input_stream_new_from_cursor does NOT copy the data —
    // it stores the pointer from the cursor. We must keep `body_data` alive
    // (and un-reallocated) for the entire request lifetime. The Vec is
    // stored in RequestContext and outlives the input stream.
    let (body_stream, body_data) = if let Some(owned) = opts.body {
        if !owned.is_empty() {
            let cursor = AwsByteCursor::from_slice(&owned);
            let stream = unsafe {
                aws_input_stream_new_from_cursor(allocator, &cursor)
            };
            if stream.is_null() {
                unsafe { aws_http_message_release(request) };
                return Err(CrtError::last_error());
            }
            unsafe { aws_http_message_set_body_stream(request, stream) };
            (stream, Some(owned))
        } else {
            (std::ptr::null_mut(), None)
        }
    } else {
        (std::ptr::null_mut(), None)
    };

    // Set up shared state
    let state: SharedState = Arc::new((
        Mutex::new(RequestState {
            status_code: 0,
            headers: Vec::new(),
            body: Vec::new(),
            chunks: VecDeque::new(),
            streaming: opts.streaming,
            error_code: 0,
            complete: false,
            connection: std::ptr::null_mut(),
            manager: opts.manager,
        }),
        Condvar::new(),
    ));

    let ctx = Box::new(RequestContext {
        state: Arc::clone(&state),
        request,
        body_stream,
        _body_data: body_data,
        response_first_byte_timeout_ms: opts.read_timeout_ms,
    });
    let ctx_ptr = Box::into_raw(ctx);

    Ok((ctx_ptr, state))
}

/// Clean up a RequestContext after the request is complete.
///
/// # Safety
/// `ctx_ptr` must be a valid pointer returned by `build_request`.
unsafe fn cleanup_request_context(ctx_ptr: *mut RequestContext) {
    let ctx = Box::from_raw(ctx_ptr);
    aws_http_message_release(ctx.request);
    if !ctx.body_stream.is_null() {
        aws_input_stream_release(ctx.body_stream);
    }
    // ctx.body_data is dropped here, which is safe because the input stream
    // has already been released above.
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// The result of a buffered HTTP request.
pub struct HttpResponse {
    pub status_code: i32,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

/// Execute a buffered HTTP request on the given connection manager.
///
/// Releases the Ruby GVL during the blocking wait so other Ruby threads
/// can execute concurrently. The response is fully buffered in memory.
///
/// # Arguments
/// * `manager` - Raw pointer to the CRT connection manager
/// * `method` - HTTP method (GET, POST, etc.)
/// * `path` - Request path (e.g. "/index.html")
/// * `headers` - Request headers as (name, value) pairs
/// * `body` - Optional request body bytes
/// * `read_timeout_ms` - Read timeout in milliseconds (0 = no timeout)
pub fn make_request(
    manager: *mut AwsHttpConnectionManager,
    method: &str,
    path: &str,
    headers: &[(String, String)],
    body: Option<Vec<u8>>,
    read_timeout_ms: u64,
) -> Result<HttpResponse, CrtError> {
    let opts = RequestOptions {
        manager,
        method,
        path,
        headers,
        body,
        streaming: false,
        read_timeout_ms,
    };

    let (ctx_ptr, state) = build_request(opts)?;

    // Acquire a connection — this is async, the callback fires the request
    unsafe {
        aws_http_connection_manager_acquire_connection(
            manager,
            on_connection_acquired_with_ctx,
            ctx_ptr as *mut std::ffi::c_void,
        );
    }

    // Release the GVL and wait for the request to complete
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

    // Clean up the request context
    unsafe { cleanup_request_context(ctx_ptr) };

    // Extract the result — move data out of the mutex instead of cloning.
    // At this point the CRT callbacks are done and we hold the only
    // remaining Arc reference, so taking ownership avoids an extra
    // allocation + copy of the headers Vec and body Vec.
    let mut guard = state.0.lock().unwrap();
    if guard.error_code != 0 {
        return Err(CrtError::from_code(guard.error_code));
    }

    Ok(HttpResponse {
        status_code: guard.status_code,
        headers: std::mem::take(&mut guard.headers),
        body: std::mem::take(&mut guard.body),
    })
}

/// Execute a streaming HTTP request on the given connection manager.
///
/// Instead of buffering the entire response body, this function yields each
/// body chunk to the provided callback as it arrives from the CRT. The GVL
/// is released while waiting for chunks and re-acquired before each yield.
///
/// # Arguments
/// * `manager` - Raw pointer to the CRT connection manager
/// * `method` - HTTP method (GET, POST, etc.)
/// * `path` - Request path (e.g. "/index.html")
/// * `headers` - Request headers as (name, value) pairs
/// * `body` - Optional request body bytes
/// * `read_timeout_ms` - Read timeout in milliseconds (0 = no timeout)
/// * `on_chunk` - Called with each body chunk (while GVL is held)
///
/// # Returns
/// The response status code and headers (body was already streamed).
/// Execute a streaming HTTP request on the given connection manager.
///
/// Instead of buffering the entire response body, this function yields each
/// body chunk to the provided callback as it arrives from the CRT. The GVL
/// is released while waiting for chunks and re-acquired before each yield.
///
/// Headers and status code are delivered via `on_headers` before any body
/// chunks are yielded via `on_chunk`. This matches the HTTP protocol order
/// (headers arrive before body) and allows callers to inspect the status
/// code and headers before processing body data.
///
/// # Arguments
/// * `manager` - Raw pointer to the CRT connection manager
/// * `method` - HTTP method (GET, POST, etc.)
/// * `path` - Request path (e.g. "/index.html")
/// * `headers` - Request headers as (name, value) pairs
/// * `body` - Optional request body bytes
/// * `read_timeout_ms` - Read timeout in milliseconds (0 = no timeout)
/// * `on_headers` - Called once with (status_code, headers) before body chunks
/// * `on_chunk` - Called with each body chunk (while GVL is held)
///
/// # Returns
/// Ok(()) on success, or a CrtError on failure.
pub fn make_streaming_request<H, F>(
    manager: *mut AwsHttpConnectionManager,
    method: &str,
    path: &str,
    headers: &[(String, String)],
    body: Option<Vec<u8>>,
    read_timeout_ms: u64,
    mut on_headers: H,
    mut on_chunk: F,
) -> Result<(), CrtError>
where
    H: FnMut(i32, &[(String, String)]),
    F: FnMut(&[u8]),
{
    let opts = RequestOptions {
        manager,
        method,
        path,
        headers,
        body,
        streaming: true,
        read_timeout_ms,
    };

    let (ctx_ptr, state) = build_request(opts)?;

    // Acquire a connection
    unsafe {
        aws_http_connection_manager_acquire_connection(
            manager,
            on_connection_acquired_with_ctx,
            ctx_ptr as *mut std::ffi::c_void,
        );
    }

    // Streaming loop: release GVL → wait for chunk or completion →
    // re-acquire GVL → yield headers/chunks → repeat
    let wait_data = WaitData {
        state: Arc::clone(&state),
    };

    let mut headers_delivered = false;

    loop {
        // Release GVL and wait for data
        unsafe {
            rb_thread_call_without_gvl(
                wait_for_chunk_or_completion,
                &wait_data as *const WaitData as *mut std::ffi::c_void,
                std::ptr::null(),
                std::ptr::null(),
            );
        }

        // GVL is re-acquired here — drain available chunks
        let (status_code, resp_headers, chunks, complete, error_code) = {
            let mut guard = state.0.lock().unwrap();
            let chunks: Vec<Vec<u8>> = guard.chunks.drain(..).collect();
            (
                guard.status_code,
                guard.headers.clone(),
                chunks,
                guard.complete,
                guard.error_code,
            )
        };

        // Deliver headers once, before any body chunks
        if !headers_delivered && status_code > 0 {
            on_headers(status_code, &resp_headers);
            headers_delivered = true;
        }

        // Yield each chunk to the callback (with GVL held)
        for chunk in &chunks {
            on_chunk(chunk);
        }

        if complete {
            // Clean up and return
            unsafe { cleanup_request_context(ctx_ptr) };

            if error_code != 0 {
                return Err(CrtError::from_code(error_code));
            }

            // Deliver headers if they weren't delivered yet (e.g. empty body)
            if !headers_delivered && status_code > 0 {
                on_headers(status_code, &resp_headers);
            }

            return Ok(());
        }
    }
}
