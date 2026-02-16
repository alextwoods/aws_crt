//! CRT HTTP connection pool (connection manager) wrapper.
//!
//! Each `ConnectionManager` owns a CRT `aws_http_connection_manager` bound to
//! a single endpoint (host + port). The CRT handles connection creation, reuse,
//! keep-alive, idle cleanup, and queuing internally.

use std::ffi::CString;

use crate::error::CrtError;
use crate::proxy::{ProxyAuthType, ProxyOptions};
use crate::runtime::{AwsAllocator, AwsClientBootstrap, CrtRuntime};
use crate::tls::{AwsTlsCtx, TlsContext, TlsOptions};

// ---------------------------------------------------------------------------
// Opaque CRT types
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct AwsHttpConnectionManager {
    _opaque: [u8; 0],
}

#[repr(C)]
pub struct AwsHttpConnection {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// FFI struct mirrors
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_byte_cursor` from aws-c-common/byte_buf.h.
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

    fn null() -> Self {
        Self {
            len: 0,
            ptr: std::ptr::null(),
        }
    }
}

/// Mirrors `struct aws_socket_options` from aws-c-io/socket.h.
/// Size: 40 bytes, align: 4 on ARM64 macOS.
#[repr(C)]
struct AwsSocketOptions {
    socket_type: u32,                       // enum aws_socket_type
    domain: u32,                            // enum aws_socket_domain
    impl_type: u32,                         // enum aws_socket_impl_type
    connect_timeout_ms: u32,
    keep_alive_interval_sec: u16,
    keep_alive_timeout_sec: u16,
    keep_alive_max_failed_probes: u16,
    keepalive: bool,
    network_interface_name: [u8; 16],       // AWS_NETWORK_INTERFACE_NAME_MAX = 16
}

/// Opaque buffer for `aws_tls_connection_options` (64 bytes, align 8 on ARM64).
/// Initialized via `aws_tls_connection_options_init_from_ctx`.
#[repr(C, align(8))]
struct TlsConnectionOptionsBuffer {
    _data: [u8; 128], // generous upper bound (actual: 64 bytes)
}

/// Mirrors `struct aws_http_proxy_options` from aws-c-http/proxy.h.
#[repr(C)]
struct AwsHttpProxyOptions {
    connection_type: u32,                   // enum aws_http_proxy_connection_type
    _pad0: u32,
    host: AwsByteCursor,
    port: u32,
    _pad1: u32,
    tls_options: *const std::ffi::c_void,   // *const aws_tls_connection_options
    proxy_strategy: *const std::ffi::c_void,
    auth_type: u32,                         // enum aws_http_proxy_authentication_type
    _pad2: u32,
    auth_username: AwsByteCursor,
    auth_password: AwsByteCursor,
    no_proxy_hosts: AwsByteCursor,
}

/// Mirrors `struct aws_http_connection_manager_options`.
/// Size: 200 bytes, align: 8 on ARM64 macOS.
#[repr(C)]
struct AwsHttpConnectionManagerOptions {
    bootstrap: *mut AwsClientBootstrap,
    initial_window_size: usize,
    socket_options: *const AwsSocketOptions,
    response_first_byte_timeout_ms: u64,
    tls_connection_options: *const TlsConnectionOptionsBuffer,
    http2_prior_knowledge: bool,
    _pad0: [u8; 7],
    monitoring_options: *const std::ffi::c_void,
    host: AwsByteCursor,
    port: u32,
    _pad1: u32,
    initial_settings_array: *const std::ffi::c_void,
    num_initial_settings: usize,
    max_closed_streams: usize,
    http2_conn_manual_window_management: bool,
    _pad2: [u8; 7],
    proxy_options: *const AwsHttpProxyOptions,
    proxy_ev_settings: *const std::ffi::c_void,
    max_connections: usize,
    shutdown_complete_user_data: *mut std::ffi::c_void,
    shutdown_complete_callback: *const std::ffi::c_void,
    enable_read_back_pressure: bool,
    _pad3: [u8; 7],
    max_connection_idle_in_milliseconds: u64,
    connection_acquisition_timeout_ms: u64,
    max_pending_connection_acquisitions: u64,
    network_interface_names_array: *const std::ffi::c_void,
    num_network_interface_names: usize,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_http_connection_manager_new(
        allocator: *mut AwsAllocator,
        options: *const AwsHttpConnectionManagerOptions,
    ) -> *mut AwsHttpConnectionManager;

    fn aws_http_connection_manager_release(manager: *mut AwsHttpConnectionManager);

    fn aws_tls_connection_options_init_from_ctx(
        conn_options: *mut TlsConnectionOptionsBuffer,
        ctx: *mut AwsTlsCtx,
    );

    fn aws_tls_connection_options_set_server_name(
        conn_options: *mut TlsConnectionOptionsBuffer,
        allocator: *mut AwsAllocator,
        server_name: *const AwsByteCursor,
    ) -> i32;

    fn aws_tls_connection_options_clean_up(
        conn_options: *mut TlsConnectionOptionsBuffer,
    );
}

// ---------------------------------------------------------------------------
// ConnectionManager — wraps aws_http_connection_manager
// ---------------------------------------------------------------------------

/// Configuration for creating a connection manager.
pub struct ConnectionManagerOptions {
    pub host: String,
    pub port: u32,
    /// Maximum concurrent connections (default: 25).
    pub max_connections: usize,
    /// Close idle connections after this many milliseconds (default: 60_000).
    pub max_connection_idle_ms: u64,
    /// Connection timeout in milliseconds (default: 60_000).
    pub connect_timeout_ms: u32,
    /// TLS options (None for plaintext HTTP).
    pub tls_options: Option<TlsOptions>,
    /// Proxy configuration (None for direct connections).
    pub proxy_options: Option<ProxyOptions>,
}

impl Default for ConnectionManagerOptions {
    fn default() -> Self {
        Self {
            host: String::new(),
            port: 443,
            max_connections: 25,
            max_connection_idle_ms: 60_000,
            connect_timeout_ms: 60_000,
            tls_options: None,
            proxy_options: None,
        }
    }
}

/// A CRT HTTP connection pool for a single endpoint.
///
/// Wraps `aws_http_connection_manager`. The CRT handles connection creation,
/// reuse, keep-alive, idle cleanup, and queuing internally. Thread-safe.
pub struct ConnectionManager {
    manager: *mut AwsHttpConnectionManager,
    // Hold ownership of TLS context so it outlives the connection manager
    _tls_ctx: Option<TlsContext>,
}

unsafe impl Send for ConnectionManager {}
unsafe impl Sync for ConnectionManager {}

impl ConnectionManager {
    /// Create a new connection pool for the given endpoint.
    pub fn new(opts: &ConnectionManagerOptions) -> Result<Self, CrtError> {
        let rt = CrtRuntime::get();
        let allocator = rt.allocator();

        // Host as bytes for aws_byte_cursor (must outlive the options struct)
        let host_bytes = opts.host.as_bytes();
        let host_cursor = AwsByteCursor::from_slice(host_bytes);

        // Socket options — TCP stream with configured connect timeout
        let socket_options = AwsSocketOptions {
            socket_type: 0,  // AWS_SOCKET_STREAM
            domain: 0,       // AWS_SOCKET_IPV4
            impl_type: 0,    // AWS_SOCKET_IMPL_PLATFORM_DEFAULT
            connect_timeout_ms: opts.connect_timeout_ms,
            keep_alive_interval_sec: 0,
            keep_alive_timeout_sec: 0,
            keep_alive_max_failed_probes: 0,
            keepalive: false,
            network_interface_name: [0u8; 16],
        };

        // TLS context and connection options (if HTTPS)
        let tls_ctx = match &opts.tls_options {
            Some(tls_opts) => Some(TlsContext::new(tls_opts)?),
            None => None,
        };

        let mut tls_conn_opts =
            std::mem::MaybeUninit::<TlsConnectionOptionsBuffer>::zeroed();
        let tls_conn_ptr = if let Some(ref ctx) = tls_ctx {
            let ptr = tls_conn_opts.as_mut_ptr();
            unsafe {
                aws_tls_connection_options_init_from_ctx(ptr, ctx.as_ptr());
                // Set SNI to the host name
                let name_cursor = AwsByteCursor::from_slice(host_bytes);
                let rc = aws_tls_connection_options_set_server_name(
                    ptr,
                    allocator,
                    &name_cursor,
                );
                if rc != 0 {
                    aws_tls_connection_options_clean_up(ptr);
                    return Err(CrtError::last_error());
                }
            }
            tls_conn_opts.as_ptr()
        } else {
            std::ptr::null()
        };

        // Proxy options (if configured)
        // Keep CStrings alive for the duration of the options struct
        let _proxy_host_c: Option<CString>;
        let _proxy_user_c: Option<CString>;
        let _proxy_pass_c: Option<CString>;

        let proxy_opts = match &opts.proxy_options {
            Some(proxy) => {
                _proxy_host_c = Some(
                    CString::new(proxy.host.as_str())
                        .map_err(|_| CrtError::from_code(0))?,
                );
                let host_c = _proxy_host_c.as_ref().unwrap();

                let (auth_type, username_cursor, password_cursor) =
                    match proxy.auth_type {
                        ProxyAuthType::Basic => {
                            let user = proxy
                                .auth_username
                                .as_deref()
                                .unwrap_or("");
                            let pass = proxy
                                .auth_password
                                .as_deref()
                                .unwrap_or("");
                            _proxy_user_c =
                                Some(CString::new(user).unwrap_or_default());
                            _proxy_pass_c =
                                Some(CString::new(pass).unwrap_or_default());
                            (
                                1u32, // AWS_HPAT_BASIC
                                AwsByteCursor::from_slice(
                                    _proxy_user_c
                                        .as_ref()
                                        .unwrap()
                                        .as_bytes(),
                                ),
                                AwsByteCursor::from_slice(
                                    _proxy_pass_c
                                        .as_ref()
                                        .unwrap()
                                        .as_bytes(),
                                ),
                            )
                        }
                        ProxyAuthType::None => {
                            _proxy_user_c = None;
                            _proxy_pass_c = None;
                            (
                                0u32, // AWS_HPAT_NONE
                                AwsByteCursor::null(),
                                AwsByteCursor::null(),
                            )
                        }
                    };

                Some(AwsHttpProxyOptions {
                    connection_type: 0, // AWS_HPCT_HTTP_LEGACY
                    _pad0: 0,
                    host: AwsByteCursor::from_slice(host_c.as_bytes()),
                    port: proxy.port,
                    _pad1: 0,
                    tls_options: std::ptr::null(),
                    proxy_strategy: std::ptr::null(),
                    auth_type,
                    _pad2: 0,
                    auth_username: username_cursor,
                    auth_password: password_cursor,
                    no_proxy_hosts: AwsByteCursor::null(),
                })
            }
            None => {
                _proxy_host_c = None;
                _proxy_user_c = None;
                _proxy_pass_c = None;
                None
            }
        };

        let proxy_ptr = match &proxy_opts {
            Some(p) => p as *const AwsHttpProxyOptions,
            None => std::ptr::null(),
        };

        // Build the connection manager options
        let cm_options = AwsHttpConnectionManagerOptions {
            bootstrap: rt.client_bootstrap(),
            initial_window_size: usize::MAX, // no flow control
            socket_options: &socket_options,
            response_first_byte_timeout_ms: 0,
            tls_connection_options: tls_conn_ptr,
            http2_prior_knowledge: false,
            _pad0: [0; 7],
            monitoring_options: std::ptr::null(),
            host: host_cursor,
            port: opts.port,
            _pad1: 0,
            initial_settings_array: std::ptr::null(),
            num_initial_settings: 0,
            max_closed_streams: 0,
            http2_conn_manual_window_management: false,
            _pad2: [0; 7],
            proxy_options: proxy_ptr,
            proxy_ev_settings: std::ptr::null(),
            max_connections: opts.max_connections,
            shutdown_complete_user_data: std::ptr::null_mut(),
            shutdown_complete_callback: std::ptr::null(),
            enable_read_back_pressure: false,
            _pad3: [0; 7],
            max_connection_idle_in_milliseconds: opts.max_connection_idle_ms,
            connection_acquisition_timeout_ms: opts.connect_timeout_ms as u64,
            max_pending_connection_acquisitions: 0,
            network_interface_names_array: std::ptr::null(),
            num_network_interface_names: 0,
        };

        let manager =
            unsafe { aws_http_connection_manager_new(allocator, &cm_options) };

        // Clean up TLS connection options (the CRT deep-copies what it needs)
        if !tls_conn_ptr.is_null() {
            unsafe {
                aws_tls_connection_options_clean_up(
                    tls_conn_opts.as_mut_ptr(),
                );
            }
        }

        if manager.is_null() {
            return Err(CrtError::last_error());
        }

        Ok(ConnectionManager {
            manager,
            _tls_ctx: tls_ctx,
        })
    }

    /// Returns the raw connection manager pointer for use by `http.rs`.
    pub fn as_ptr(&self) -> *mut AwsHttpConnectionManager {
        self.manager
    }
}

impl Drop for ConnectionManager {
    fn drop(&mut self) {
        unsafe { aws_http_connection_manager_release(self.manager) };
    }
}
