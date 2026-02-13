//! CRT credentials provider bridge.
//!
//! Wraps the CRT's `aws_credentials_provider` with a safe Rust interface.
//! Currently supports static credentials (access key, secret key, optional
//! session token). The provider is ref-counted by the CRT; `Drop` releases
//! our reference.

use crate::error::CrtError;
use crate::runtime::{AwsAllocator, CrtRuntime};

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct AwsCredentialsProvider {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// FFI struct definitions
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_byte_cursor` from aws-c-common/byte_buf.h.
///
/// Layout: `{ len: size_t, ptr: *const uint8_t }`.
/// The comment in the C header explicitly says "do not reorder".
#[repr(C)]
pub struct AwsByteCursor {
    pub len: usize,
    pub ptr: *const u8,
}

impl AwsByteCursor {
    /// Create a byte cursor from a Rust string slice.
    pub fn from_str(s: &str) -> Self {
        Self {
            len: s.len(),
            ptr: s.as_ptr(),
        }
    }

    /// Create an empty (zero-length, null-pointer) byte cursor.
    pub fn empty() -> Self {
        Self {
            len: 0,
            ptr: std::ptr::null(),
        }
    }
}

/// Mirrors `struct aws_credentials_provider_shutdown_options` from
/// aws-c-auth/credentials.h.
///
/// Layout: `{ shutdown_callback: fn ptr, shutdown_user_data: *mut c_void }`.
#[repr(C)]
struct AwsCredentialsProviderShutdownOptions {
    shutdown_callback: *const std::ffi::c_void,
    shutdown_user_data: *const std::ffi::c_void,
}

/// Mirrors `struct aws_credentials_provider_static_options` from
/// aws-c-auth/credentials.h.
///
/// Fields:
///   - shutdown_options
///   - access_key_id (aws_byte_cursor)
///   - secret_access_key (aws_byte_cursor)
///   - session_token (aws_byte_cursor)
///   - account_id (aws_byte_cursor)
#[repr(C)]
struct AwsCredentialsProviderStaticOptions {
    shutdown_options: AwsCredentialsProviderShutdownOptions,
    access_key_id: AwsByteCursor,
    secret_access_key: AwsByteCursor,
    session_token: AwsByteCursor,
    account_id: AwsByteCursor,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_credentials_provider_new_static(
        allocator: *mut AwsAllocator,
        options: *const AwsCredentialsProviderStaticOptions,
    ) -> *mut AwsCredentialsProvider;

    fn aws_credentials_provider_release(
        provider: *mut AwsCredentialsProvider,
    ) -> *mut AwsCredentialsProvider;
}

// ---------------------------------------------------------------------------
// CredentialsProvider — wraps aws_credentials_provider
// ---------------------------------------------------------------------------

/// A CRT credentials provider wrapping `aws_credentials_provider`.
///
/// Created via `CredentialsProvider::new_static()` with fixed credentials.
/// The provider is ref-counted by the CRT; `Drop` releases our reference.
pub struct CredentialsProvider {
    provider: *mut AwsCredentialsProvider,
}

// The CRT credentials provider is internally thread-safe and ref-counted.
unsafe impl Send for CredentialsProvider {}
unsafe impl Sync for CredentialsProvider {}

impl CredentialsProvider {
    /// Create a static credentials provider from access key, secret key,
    /// and optional session token.
    ///
    /// The CRT copies the credential strings internally, so the input
    /// slices do not need to outlive this call.
    pub fn new_static(
        access_key_id: &str,
        secret_access_key: &str,
        session_token: Option<&str>,
    ) -> Result<Self, CrtError> {
        let rt = CrtRuntime::get();
        let allocator = rt.allocator();

        let options = AwsCredentialsProviderStaticOptions {
            shutdown_options: AwsCredentialsProviderShutdownOptions {
                shutdown_callback: std::ptr::null(),
                shutdown_user_data: std::ptr::null(),
            },
            access_key_id: AwsByteCursor::from_str(access_key_id),
            secret_access_key: AwsByteCursor::from_str(secret_access_key),
            session_token: session_token
                .map(AwsByteCursor::from_str)
                .unwrap_or_else(AwsByteCursor::empty),
            account_id: AwsByteCursor::empty(),
        };

        let provider = unsafe {
            aws_credentials_provider_new_static(allocator, &options)
        };

        if provider.is_null() {
            return Err(CrtError::last_error());
        }

        Ok(Self { provider })
    }

    /// Returns the raw `aws_credentials_provider` pointer for use by
    /// the signing config and S3 client.
    pub fn as_ptr(&self) -> *mut AwsCredentialsProvider {
        self.provider
    }
}

impl Drop for CredentialsProvider {
    fn drop(&mut self) {
        unsafe {
            aws_credentials_provider_release(self.provider);
        }
    }
}
