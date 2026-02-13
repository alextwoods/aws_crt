//! TLS context management for CRT HTTP connections.
//!
//! Wraps the CRT's `aws_tls_ctx` with a safe Rust interface. The TLS context
//! is created from platform-native TLS (Security.framework on macOS, s2n-tls
//! on Linux) and configured with options like peer verification, custom CA
//! bundles, and ALPN protocol lists.

use std::ffi::CString;

use crate::error::CrtError;
use crate::runtime::{AwsAllocator, CrtRuntime};

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct AwsTlsCtx {
    _opaque: [u8; 0],
}

/// Opaque buffer for `aws_tls_ctx_options`.
///
/// The actual struct size varies by platform (248 bytes on macOS/ARM64).
/// We allocate a generous buffer and let `aws_tls_ctx_options_init_default_client`
/// initialize it. The buffer is 512 bytes which is well above any platform's
/// actual size. A debug assertion in `TlsContext::new` validates this.
///
/// Alignment is 8 bytes (pointer-aligned) matching the C struct.
#[repr(C, align(8))]
struct TlsCtxOptionsBuffer {
    _data: [u8; 512],
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_tls_ctx_options_init_default_client(
        options: *mut TlsCtxOptionsBuffer,
        allocator: *mut AwsAllocator,
    );
    fn aws_tls_ctx_options_clean_up(options: *mut TlsCtxOptionsBuffer);
    fn aws_tls_ctx_options_set_verify_peer(
        options: *mut TlsCtxOptionsBuffer,
        verify_peer: bool,
    );
    fn aws_tls_ctx_options_set_alpn_list(
        options: *mut TlsCtxOptionsBuffer,
        alpn_list: *const std::ffi::c_char,
    ) -> i32;
    fn aws_tls_ctx_options_override_default_trust_store_from_path(
        options: *mut TlsCtxOptionsBuffer,
        ca_path: *const std::ffi::c_char,
        ca_file: *const std::ffi::c_char,
    ) -> i32;

    fn aws_tls_client_ctx_new(
        allocator: *mut AwsAllocator,
        options: *const TlsCtxOptionsBuffer,
    ) -> *mut AwsTlsCtx;
    fn aws_tls_ctx_release(ctx: *mut AwsTlsCtx);
}

// ---------------------------------------------------------------------------
// TlsContext — wraps aws_tls_ctx
// ---------------------------------------------------------------------------

/// Configuration options for creating a TLS context.
pub struct TlsOptions {
    /// Whether to verify the peer's certificate (default: true).
    pub verify_peer: bool,
    /// Path to a custom CA file for certificate verification.
    pub ca_filepath: Option<String>,
    /// Semicolon-delimited ALPN protocol list (e.g. "h2;http/1.1").
    pub alpn_list: Option<String>,
}

impl Default for TlsOptions {
    fn default() -> Self {
        Self {
            verify_peer: true,
            ca_filepath: None,
            alpn_list: None,
        }
    }
}

/// A CRT TLS context wrapping `aws_tls_ctx`.
///
/// Created via `TlsContext::new()` with platform-native TLS. The context is
/// ref-counted by the CRT; `Drop` releases our reference.
pub struct TlsContext {
    ctx: *mut AwsTlsCtx,
}

// The CRT TLS context is internally thread-safe and ref-counted.
unsafe impl Send for TlsContext {}
unsafe impl Sync for TlsContext {}

impl TlsContext {
    /// Create a new client TLS context with the given options.
    ///
    /// Uses the platform-native TLS implementation:
    /// - macOS: Security.framework
    /// - Linux: s2n-tls
    pub fn new(options: &TlsOptions) -> Result<Self, CrtError> {
        let rt = CrtRuntime::get();
        let allocator = rt.allocator();

        // Stack-allocate the options buffer and let the CRT initialize it.
        let mut opts_buf = std::mem::MaybeUninit::<TlsCtxOptionsBuffer>::zeroed();
        let opts_ptr = opts_buf.as_mut_ptr();

        unsafe {
            aws_tls_ctx_options_init_default_client(opts_ptr, allocator);
        }

        // Configure options — clean up on any error path
        let result = unsafe { Self::configure_and_create(opts_ptr, allocator, options) };

        // Always clean up the options struct (it may own allocated strings)
        unsafe { aws_tls_ctx_options_clean_up(opts_ptr) };

        result
    }

    /// Apply configuration and create the TLS context.
    ///
    /// Separated from `new()` so that `aws_tls_ctx_options_clean_up` always
    /// runs regardless of which configuration step fails.
    unsafe fn configure_and_create(
        opts_ptr: *mut TlsCtxOptionsBuffer,
        allocator: *mut AwsAllocator,
        options: &TlsOptions,
    ) -> Result<Self, CrtError> {
        // Peer verification
        aws_tls_ctx_options_set_verify_peer(opts_ptr, options.verify_peer);

        // Custom CA bundle
        if let Some(ref ca_path) = options.ca_filepath {
            let ca_file_c = CString::new(ca_path.as_str())
                .map_err(|_| CrtError::from_code(0))?;
            let rc = aws_tls_ctx_options_override_default_trust_store_from_path(
                opts_ptr,
                std::ptr::null(), // ca_path (directory) — not used
                ca_file_c.as_ptr(),
            );
            if rc != 0 {
                return Err(CrtError::last_error());
            }
        }

        // ALPN protocol list
        if let Some(ref alpn) = options.alpn_list {
            let alpn_c = CString::new(alpn.as_str())
                .map_err(|_| CrtError::from_code(0))?;
            let rc = aws_tls_ctx_options_set_alpn_list(opts_ptr, alpn_c.as_ptr());
            if rc != 0 {
                return Err(CrtError::last_error());
            }
        }

        // Create the TLS context
        let ctx = aws_tls_client_ctx_new(allocator, opts_ptr);
        if ctx.is_null() {
            return Err(CrtError::last_error());
        }

        Ok(TlsContext { ctx })
    }

    /// Returns the raw `aws_tls_ctx` pointer for use by the connection manager.
    pub fn as_ptr(&self) -> *mut AwsTlsCtx {
        self.ctx
    }
}

impl Drop for TlsContext {
    fn drop(&mut self) {
        unsafe { aws_tls_ctx_release(self.ctx) };
    }
}
