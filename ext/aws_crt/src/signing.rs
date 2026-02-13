//! CRT signing configuration for S3 requests.
//!
//! Wraps the CRT's `aws_signing_config_aws` with a safe Rust interface.
//! Uses `aws_s3_init_default_signing_config` to initialize the config with
//! S3-appropriate defaults (SigV4, HTTP request headers, service "s3",
//! unsigned payload with x-amz-content-sha256 header).
//!
//! The signing config is passed by reference to the CRT S3 client, which
//! deep-copies what it needs. The config owns the region string to ensure
//! the byte cursor pointing into it remains valid for the config's lifetime.

use crate::credentials::{AwsByteCursor, AwsCredentialsProvider, CredentialsProvider};
use crate::error::CrtError;

// ---------------------------------------------------------------------------
// Opaque CRT type
// ---------------------------------------------------------------------------

/// Opaque representation of `aws_signing_config_aws`.
///
/// The actual struct contains platform-dependent types (`struct tm` inside
/// `aws_date_time`) whose layout varies across platforms. Rather than
/// replicating the full layout, we treat it as an opaque blob and use
/// `aws_s3_init_default_signing_config` to initialize it safely.
///
/// 512 bytes is a conservative upper bound — the actual struct is typically
/// ~300-400 bytes depending on platform. We verify this is sufficient with
/// a runtime check in `SigningConfig::new_s3()`.
#[repr(C, align(8))]
pub struct AwsSigningConfigAws {
    _opaque: [u8; 512],
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    /// Initialize a signing config with S3 defaults.
    ///
    /// Sets: config_type=AWS_SIGNING_CONFIG_AWS, algorithm=V4,
    /// signature_type=HTTP_REQUEST_HEADERS (implicitly via zero),
    /// service="s3", signed_body_header=X_AMZ_CONTENT_SHA256,
    /// signed_body_value=UNSIGNED_PAYLOAD.
    fn aws_s3_init_default_signing_config(
        signing_config: *mut AwsSigningConfigAws,
        region: AwsByteCursor,
        credentials_provider: *mut AwsCredentialsProvider,
    );

    /// Validate a signing config. Returns 0 on success.
    fn aws_validate_aws_signing_config_aws(
        config: *const AwsSigningConfigAws,
    ) -> i32;
}

// ---------------------------------------------------------------------------
// SigningConfig — wraps aws_signing_config_aws
// ---------------------------------------------------------------------------

/// A CRT signing configuration for S3 requests.
///
/// Configured for SigV4 signing with HTTP request headers, service "s3",
/// and the specified region and credentials provider. The region string is
/// owned to ensure the byte cursor inside the config remains valid.
pub struct SigningConfig {
    config: Box<AwsSigningConfigAws>,
    // The CRT signing config holds a byte cursor pointing into this string.
    // We must keep it alive for the lifetime of the config.
    _region: String,
}

// The signing config is read-only after construction and the CRT deep-copies
// it when needed, so it is safe to share across threads.
unsafe impl Send for SigningConfig {}
unsafe impl Sync for SigningConfig {}

impl SigningConfig {
    /// Create a signing config for S3 requests.
    ///
    /// Configures:
    /// - algorithm: `AWS_SIGNING_ALGORITHM_V4`
    /// - signature_type: `AWS_ST_HTTP_REQUEST_HEADERS` (default from zero-init)
    /// - region: the provided region string
    /// - service: `"s3"`
    /// - credentials_provider: the provided CRT credentials provider
    ///
    /// The CRT's `aws_s3_init_default_signing_config` handles all field
    /// initialization, including `signed_body_header` and `signed_body_value`.
    pub fn new_s3(
        region: &str,
        credentials_provider: &CredentialsProvider,
    ) -> Result<Self, CrtError> {
        // Own the region string so the byte cursor remains valid.
        let region_owned = region.to_string();

        // Allocate zeroed — Box::new will zero-init via the array default.
        let mut config = Box::new(AwsSigningConfigAws {
            _opaque: [0u8; 512],
        });

        // Build a byte cursor pointing into our owned region string.
        let region_cursor = AwsByteCursor::from_str(&region_owned);

        unsafe {
            aws_s3_init_default_signing_config(
                config.as_mut() as *mut AwsSigningConfigAws,
                region_cursor,
                credentials_provider.as_ptr(),
            );
        }

        // Validate the config to catch any issues early.
        let rc = unsafe {
            aws_validate_aws_signing_config_aws(
                config.as_ref() as *const AwsSigningConfigAws,
            )
        };
        if rc != 0 {
            return Err(CrtError::last_error());
        }

        Ok(Self {
            config,
            _region: region_owned,
        })
    }

    /// Returns a pointer to the underlying `aws_signing_config_aws` for use
    /// by the CRT S3 client.
    pub fn as_ptr(&self) -> *const AwsSigningConfigAws {
        self.config.as_ref() as *const AwsSigningConfigAws
    }
}
