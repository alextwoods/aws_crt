use std::ffi::CStr;
use std::sync::OnceLock;

use magnus::exception::ExceptionClass;
use magnus::rb_sys::{AsRawValue, FromRawValue};
use magnus::{Error, Module, Ruby, Value};
use rb_sys::VALUE;

// ---------------------------------------------------------------------------
// FFI bindings for CRT error functions (aws-c-common)
// ---------------------------------------------------------------------------
extern "C" {
    fn aws_last_error() -> i32;
    fn aws_error_name(err: i32) -> *const std::ffi::c_char;
    fn aws_error_str(err: i32) -> *const std::ffi::c_char;
}

// ---------------------------------------------------------------------------
// Ruby exception class cache (OnceLock for Ractor/thread safety)
// ---------------------------------------------------------------------------

static HTTP_ERROR: OnceLock<VALUE> = OnceLock::new();
static HTTP_CONNECTION_ERROR: OnceLock<VALUE> = OnceLock::new();
static HTTP_TIMEOUT_ERROR: OnceLock<VALUE> = OnceLock::new();
static HTTP_TLS_ERROR: OnceLock<VALUE> = OnceLock::new();
static HTTP_PROXY_ERROR: OnceLock<VALUE> = OnceLock::new();

/// Register the HTTP error hierarchy under `AwsCrt::Http` and cache the
/// exception classes for later use by `CrtError`.
///
/// Must be called exactly once during `#[magnus::init]`.
pub fn define_http_errors(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let aws_crt_module: magnus::RModule = ruby
        .class_object()
        .const_get("AwsCrt")?;
    let base_error: ExceptionClass = aws_crt_module
        .const_get("Error")?;

    let error = http_module.define_error("Error", base_error)?;
    let connection_error = http_module.define_error("ConnectionError", error)?;
    let timeout_error = http_module.define_error("TimeoutError", error)?;
    let tls_error = http_module.define_error("TlsError", error)?;
    let proxy_error = http_module.define_error("ProxyError", error)?;

    HTTP_ERROR.set(error.as_raw()).ok();
    HTTP_CONNECTION_ERROR.set(connection_error.as_raw()).ok();
    HTTP_TIMEOUT_ERROR.set(timeout_error.as_raw()).ok();
    HTTP_TLS_ERROR.set(tls_error.as_raw()).ok();
    HTTP_PROXY_ERROR.set(proxy_error.as_raw()).ok();

    Ok(())
}

/// Retrieve a cached exception class from its raw VALUE.
///
/// SAFETY: Must only be called after `define_http_errors` has run and
/// while the GVL is held.
unsafe fn exception_class(lock: &OnceLock<VALUE>) -> ExceptionClass {
    let raw = *lock.get().expect("error class not initialized");
    let val = Value::from_raw(raw);
    ExceptionClass::from_value(val)
        .expect("cached VALUE is not an ExceptionClass")
}

// ---------------------------------------------------------------------------
// CrtError — wraps a CRT error code
// ---------------------------------------------------------------------------

/// A CRT error captured from `aws_last_error()` or an explicit error code.
///
/// Carries the numeric code, the CRT error name (e.g. `AWS_IO_DNS_QUERY_FAILED`),
/// and the human-readable message. Converts to the appropriate Ruby exception
/// subclass via `From<CrtError> for magnus::Error`.
#[derive(Debug)]
pub struct CrtError {
    code: i32,
    name: String,
    message: String,
}

impl CrtError {
    /// Capture the last CRT error on the current thread.
    pub fn last_error() -> Self {
        let code = unsafe { aws_last_error() };
        Self::from_code(code)
    }

    /// Build a `CrtError` from an explicit CRT error code.
    pub fn from_code(code: i32) -> Self {
        let name = unsafe {
            let ptr = aws_error_name(code);
            if ptr.is_null() {
                "UNKNOWN".to_string()
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        };
        let message = unsafe {
            let ptr = aws_error_str(code);
            if ptr.is_null() {
                "Unknown CRT error".to_string()
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        };
        Self {
            code,
            name,
            message,
        }
    }

    /// The CRT error name, e.g. `AWS_IO_DNS_QUERY_FAILED`.
    pub fn name(&self) -> &str {
        &self.name
    }
}

impl std::fmt::Display for CrtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {} ({})", self.name, self.message, self.code)
    }
}

impl From<CrtError> for Error {
    /// Convert a `CrtError` into the appropriate Ruby exception subclass.
    ///
    /// Classification is based on the CRT error name prefix:
    /// - `AWS_IO_TLS_*`           → `AwsCrt::Http::TlsError`
    /// - `AWS_IO_DNS_*`           → `AwsCrt::Http::ConnectionError`
    /// - `AWS_IO_SOCKET_TIMEOUT`  → `AwsCrt::Http::TimeoutError`
    /// - `AWS_IO_SOCKET_*`        → `AwsCrt::Http::ConnectionError`
    /// - `AWS_ERROR_HTTP_PROXY_*` → `AwsCrt::Http::ProxyError`
    /// - Everything else          → `AwsCrt::Http::Error`
    fn from(e: CrtError) -> Error {
        let klass = unsafe { classify_error(&e.name) };
        Error::new(klass, e.to_string())
    }
}

/// Pick the most specific Ruby exception class for a CRT error name.
///
/// SAFETY: Must be called while the GVL is held and after
/// `define_http_errors` has initialized the class cache.
unsafe fn classify_error(name: &str) -> ExceptionClass {
    if name.starts_with("AWS_IO_TLS_") || name == "AWS_IO_TLS_CTX_ERROR" {
        exception_class(&HTTP_TLS_ERROR)
    } else if name.starts_with("AWS_IO_DNS_") {
        exception_class(&HTTP_CONNECTION_ERROR)
    } else if name == "AWS_IO_SOCKET_TIMEOUT" {
        exception_class(&HTTP_TIMEOUT_ERROR)
    } else if name.starts_with("AWS_IO_SOCKET_") {
        exception_class(&HTTP_CONNECTION_ERROR)
    } else if name.starts_with("AWS_ERROR_HTTP_PROXY_") {
        exception_class(&HTTP_PROXY_ERROR)
    } else {
        exception_class(&HTTP_ERROR)
    }
}
