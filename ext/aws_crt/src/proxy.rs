//! HTTP proxy configuration.
//!
//! Provides a Rust-side configuration struct for proxy settings. The actual
//! CRT `aws_http_proxy_options` struct is constructed in `connection_manager.rs`
//! when creating the connection manager, since the proxy options contain
//! `aws_byte_cursor` fields that must remain valid for the duration of the
//! CRT call.

/// Proxy authentication mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyAuthType {
    /// No proxy authentication.
    None,
    /// HTTP Basic authentication (username + password).
    Basic,
}

/// Configuration for routing connections through an HTTP proxy.
#[derive(Debug, Clone)]
pub struct ProxyOptions {
    /// Proxy server hostname.
    pub host: String,
    /// Proxy server port.
    pub port: u32,
    /// Authentication type.
    pub auth_type: ProxyAuthType,
    /// Username for Basic auth (required when auth_type is Basic).
    pub auth_username: Option<String>,
    /// Password for Basic auth (required when auth_type is Basic).
    pub auth_password: Option<String>,
}
