//! CRT S3 client wrapper.
//!
//! Wraps the CRT's `aws_s3_client` with a safe Rust interface. The S3 client
//! manages connection pools, DNS harvesting, and request splitting for high-
//! throughput S3 transfers.
//!
//! The client owns a `CredentialsProvider`, `SigningConfig`, and `TlsContext`
//! to ensure they outlive the underlying CRT client (which holds pointers
//! into them). The shared CRT runtime resources (Event Loop Group, Host
//! Resolver, Client Bootstrap) are obtained from `CrtRuntime::get()`.

use crate::credentials::{AwsByteCursor, CredentialsProvider};
use crate::error::CrtError;
use crate::runtime::{AwsAllocator, AwsClientBootstrap, CrtRuntime};
use crate::signing::{AwsSigningConfigAws, SigningConfig};
use crate::tls::{AwsTlsCtx, TlsContext, TlsOptions};

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct AwsS3Client {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// TLS connection options buffer (reused from connection_manager pattern)
// ---------------------------------------------------------------------------

/// Opaque buffer for `aws_tls_connection_options`.
///
/// The actual struct is ~64 bytes on ARM64 macOS. We use a 128-byte buffer
/// as a conservative upper bound, matching the connection_manager pattern.
#[repr(C, align(8))]
struct TlsConnectionOptionsBuffer {
    _data: [u8; 128],
}

// ---------------------------------------------------------------------------
// aws_s3_client_config — full struct layout matching the C header
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_s3_client_config` from aws-c-s3/s3_client.h.
///
/// This struct has many fields. We define the full layout so the compiler
/// handles alignment and padding correctly. Fields we don't use are set to
/// zero (null pointers, 0 integers, false booleans) which the CRT treats
/// as "use defaults".
///
/// The field order and types must exactly match the C header definition.
#[repr(C)]
struct AwsS3ClientConfig {
    max_active_connections_override: u32,
    // 4 bytes implicit padding (align aws_byte_cursor to 8)
    _pad0: u32,
    region: AwsByteCursor,
    client_bootstrap: *mut AwsClientBootstrap,
    tls_mode: u32, // enum aws_s3_meta_request_tls_mode
    // 4 bytes implicit padding (align pointer to 8)
    _pad1: u32,
    tls_connection_options: *const TlsConnectionOptionsBuffer,
    fio_opts: *const std::ffi::c_void,
    signing_config: *const AwsSigningConfigAws,
    part_size: u64,
    max_part_size: u64,
    multipart_upload_threshold: u64,
    throughput_target_gbps: f64,
    memory_limit_in_bytes: u64,
    retry_strategy: *const std::ffi::c_void,
    compute_content_md5: u32, // enum aws_s3_meta_request_compute_content_md5
    // 4 bytes implicit padding (align pointer to 8)
    _pad2: u32,
    shutdown_callback: *const std::ffi::c_void,
    shutdown_callback_user_data: *const std::ffi::c_void,
    proxy_options: *const std::ffi::c_void,
    proxy_ev_settings: *const std::ffi::c_void,
    connect_timeout_ms: u32,
    // 4 bytes implicit padding (align pointer to 8)
    _pad3: u32,
    tcp_keep_alive_options: *const std::ffi::c_void,
    monitoring_options: *const std::ffi::c_void,
    enable_read_backpressure: bool,
    // 7 bytes implicit padding (align size_t to 8)
    _pad4: [u8; 7],
    initial_read_window: usize,
    enable_s3express: bool,
    // 7 bytes implicit padding (align pointer to 8)
    _pad5: [u8; 7],
    s3express_provider_override_factory: *const std::ffi::c_void,
    factory_user_data: *const std::ffi::c_void,
    network_interface_names_array: *const std::ffi::c_void,
    num_network_interface_names: usize,
    buffer_pool_factory_fn: *const std::ffi::c_void,
    buffer_pool_user_data: *const std::ffi::c_void,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    /// Initialize the S3 library. Transitively initializes aws-c-auth,
    /// aws-c-sdkutils, and the existing HTTP/IO/cal/common libraries.
    /// Safe to call multiple times — subsequent calls are no-ops.
    fn aws_s3_library_init(allocator: *mut AwsAllocator);

    /// Create a new CRT S3 client. Returns null on failure.
    fn aws_s3_client_new(
        allocator: *mut AwsAllocator,
        client_config: *const AwsS3ClientConfig,
    ) -> *mut AwsS3Client;

    /// Release a reference to the S3 client. The client is ref-counted;
    /// the actual shutdown happens asynchronously when the last reference
    /// is released.
    fn aws_s3_client_release(client: *mut AwsS3Client) -> *mut AwsS3Client;

    fn aws_tls_connection_options_init_from_ctx(
        conn_options: *mut TlsConnectionOptionsBuffer,
        ctx: *mut AwsTlsCtx,
    );

    fn aws_tls_connection_options_clean_up(
        conn_options: *mut TlsConnectionOptionsBuffer,
    );
}

// ---------------------------------------------------------------------------
// S3 library initialization — called once via OnceLock
// ---------------------------------------------------------------------------

use std::sync::Once;

static S3_LIB_INIT: Once = Once::new();

/// Ensure the CRT S3 library is initialized exactly once.
///
/// `aws_s3_library_init` transitively initializes aws-c-auth, aws-c-sdkutils,
/// and the existing HTTP/IO/cal/common stack. It is safe to call after
/// `aws_http_library_init` — the CRT tracks initialization state internally.
fn ensure_s3_library_init() {
    S3_LIB_INIT.call_once(|| {
        let allocator = CrtRuntime::get().allocator();
        unsafe { aws_s3_library_init(allocator) };
    });
}

// ---------------------------------------------------------------------------
// S3Client — wraps aws_s3_client
// ---------------------------------------------------------------------------

/// Configuration options for creating an S3 client.
pub struct S3ClientOptions {
    pub region: String,
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: Option<String>,
    pub throughput_target_gbps: f64,
    pub part_size: u64,
    pub multipart_upload_threshold: u64,
    pub memory_limit_in_bytes: u64,
    pub max_active_connections_override: u32,
}

/// A CRT S3 client wrapping `aws_s3_client`.
///
/// Owns the credentials provider, signing config, and TLS context to ensure
/// they outlive the CRT client (which holds pointers into them). The shared
/// CRT runtime resources (event loop group, host resolver, client bootstrap)
/// are obtained from `CrtRuntime::get()` and live for the process lifetime.
pub struct S3Client {
    client: *mut AwsS3Client,
    region: String,
    // Owned resources that must outlive the CRT client.
    // The CRT client holds pointers into these, so they must not be dropped
    // before the client is released.
    _credentials_provider: CredentialsProvider,
    signing_config: Box<SigningConfig>,
    _tls_ctx: TlsContext,
}

// The CRT S3 client is internally thread-safe — it manages its own
// connection pool, DNS harvesting, and request scheduling with internal locks.
unsafe impl Send for S3Client {}
unsafe impl Sync for S3Client {}

impl S3Client {
    /// Create a new CRT S3 client.
    ///
    /// Initializes the S3 library (if not already done), creates a credentials
    /// provider and signing config from the provided options, sets up TLS,
    /// and creates the underlying CRT S3 client bound to the shared bootstrap.
    pub fn new(options: S3ClientOptions) -> Result<Self, CrtError> {
        ensure_s3_library_init();

        let rt = CrtRuntime::get();
        let allocator = rt.allocator();

        // Create credentials provider
        let credentials_provider = CredentialsProvider::new_static(
            &options.access_key_id,
            &options.secret_access_key,
            options.session_token.as_deref(),
        )?;

        // Create signing config (boxed so it has a stable address)
        let signing_config = Box::new(SigningConfig::new_s3(
            &options.region,
            &credentials_provider,
        )?);

        // Create TLS context with default options (verify peer, platform-native TLS)
        let tls_ctx = TlsContext::new(&TlsOptions::default())?;

        // Initialize TLS connection options from the context
        let mut tls_conn_opts =
            std::mem::MaybeUninit::<TlsConnectionOptionsBuffer>::zeroed();
        let tls_conn_ptr = tls_conn_opts.as_mut_ptr();
        unsafe {
            aws_tls_connection_options_init_from_ctx(tls_conn_ptr, tls_ctx.as_ptr());
        }

        // Build the region byte cursor — must outlive the config struct
        let region_cursor = AwsByteCursor::from_str(&options.region);

        // Build the S3 client config
        let config = AwsS3ClientConfig {
            max_active_connections_override: options.max_active_connections_override,
            _pad0: 0,
            region: region_cursor,
            client_bootstrap: rt.client_bootstrap(),
            tls_mode: 0, // AWS_MR_TLS_ENABLED = 0
            _pad1: 0,
            tls_connection_options: tls_conn_opts.as_ptr(),
            fio_opts: std::ptr::null(),
            signing_config: signing_config.as_ptr(),
            part_size: options.part_size,
            max_part_size: 0,
            multipart_upload_threshold: options.multipart_upload_threshold,
            throughput_target_gbps: options.throughput_target_gbps,
            memory_limit_in_bytes: options.memory_limit_in_bytes,
            retry_strategy: std::ptr::null(),
            compute_content_md5: 0, // AWS_MR_CONTENT_MD5_DISABLED
            _pad2: 0,
            shutdown_callback: std::ptr::null(),
            shutdown_callback_user_data: std::ptr::null(),
            proxy_options: std::ptr::null(),
            proxy_ev_settings: std::ptr::null(),
            connect_timeout_ms: 0,
            _pad3: 0,
            tcp_keep_alive_options: std::ptr::null(),
            monitoring_options: std::ptr::null(),
            enable_read_backpressure: false,
            _pad4: [0; 7],
            initial_read_window: 0,
            enable_s3express: false,
            _pad5: [0; 7],
            s3express_provider_override_factory: std::ptr::null(),
            factory_user_data: std::ptr::null(),
            network_interface_names_array: std::ptr::null(),
            num_network_interface_names: 0,
            buffer_pool_factory_fn: std::ptr::null(),
            buffer_pool_user_data: std::ptr::null(),
        };

        let client = unsafe { aws_s3_client_new(allocator, &config) };

        // Clean up TLS connection options (the CRT deep-copies what it needs)
        unsafe { aws_tls_connection_options_clean_up(tls_conn_opts.as_mut_ptr()) };

        if client.is_null() {
            return Err(CrtError::last_error());
        }

        Ok(S3Client {
            client,
            region: options.region,
            _credentials_provider: credentials_provider,
            signing_config,
            _tls_ctx: tls_ctx,
        })
    }

    /// Returns the raw `aws_s3_client` pointer for use by meta-request
    /// execution in `s3_request.rs`.
    pub fn as_ptr(&self) -> *mut AwsS3Client {
        self.client
    }

    /// Returns a pointer to the signing config for use by meta-request
    /// options in `s3_request.rs`.
    pub fn signing_config_ptr(&self) -> *const AwsSigningConfigAws {
        self.signing_config.as_ptr()
    }

    /// Returns the region this client is configured for.
    pub fn region(&self) -> &str {
        &self.region
    }
}

impl Drop for S3Client {
    fn drop(&mut self) {
        // aws_s3_client_release is ref-counted. The actual shutdown happens
        // asynchronously when the last reference is released. The owned
        // CredentialsProvider, SigningConfig, and TlsContext are dropped
        // after this, which is safe because the CRT deep-copies what it
        // needs from them during client creation.
        unsafe {
            aws_s3_client_release(self.client);
        }
    }
}
