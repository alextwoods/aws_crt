//! Ruby-facing `AwsCrt::S3::Client` class.
//!
//! Wraps the Rust `S3Client` and `s3_request` functions, translating between
//! Ruby types (RHash, RString, Value) and the Rust S3 client types. The Ruby
//! layer (task 7) handles constructing Response objects and raising exceptions
//! — this layer returns raw data as hashes.
//!
//! # Return format
//!
//! On success: Ruby Hash with keys :status_code, :headers, :body, :checksum_validated
//! On error: Ruby Hash with keys :error, :error_code, :status_code, :headers, :body

use std::cell::RefCell;

use magnus::prelude::*;
use magnus::typed_data;
use magnus::{method, Error, RHash, RString, Ruby, Symbol, Value};

use crate::s3_client::{S3Client, S3ClientOptions};
use crate::s3_request::{self, GetObjectOptions, PutObjectOptions, S3ErrorData};

// ---------------------------------------------------------------------------
// Hash extraction helpers (same pattern as pool.rs)
// ---------------------------------------------------------------------------

/// Extract a String option from a Ruby Hash by symbol key.
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

/// Extract a required String from a Ruby Hash by symbol key.
fn hash_get_string_required(hash: &RHash, key: &str) -> Result<String, Error> {
    hash_get_string(hash, key)?.ok_or_else(|| {
        Error::new(
            magnus::exception::arg_error(),
            format!("missing required option :{}", key),
        )
    })
}

/// Extract a u64 option from a Ruby Hash by symbol key.
fn hash_get_u64(hash: &RHash, key: &str, default: u64) -> Result<u64, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: u64 = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract an optional u64 from a Ruby Hash by symbol key (None if absent/nil).
fn hash_get_optional_u64(hash: &RHash, key: &str) -> Result<Option<u64>, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(None),
        Some(v) => {
            let n: u64 = magnus::TryConvert::try_convert(v)?;
            Ok(Some(n))
        }
        None => Ok(None),
    }
}

/// Extract a u32 option from a Ruby Hash by symbol key.
fn hash_get_u32(hash: &RHash, key: &str, default: u32) -> Result<u32, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: u32 = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract an f64 option from a Ruby Hash by symbol key.
fn hash_get_f64(hash: &RHash, key: &str, default: f64) -> Result<f64, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(default),
        Some(v) => {
            let n: f64 = magnus::TryConvert::try_convert(v)?;
            Ok(n)
        }
        None => Ok(default),
    }
}

/// Extract a Value option from a Ruby Hash by symbol key (returns None if absent/nil).
fn hash_get_value(hash: &RHash, key: &str) -> Result<Option<Value>, Error> {
    let sym = Symbol::new(key);
    let val: Option<Value> = hash.lookup(sym)?;
    match val {
        Some(v) if v.is_nil() => Ok(None),
        Some(v) => Ok(Some(v)),
        None => Ok(None),
    }
}

// ---------------------------------------------------------------------------
// Response building helpers
// ---------------------------------------------------------------------------

/// Build a Ruby Hash from a successful S3Response.
///
/// Returns: { status_code: Integer, headers: Hash, body: String|nil, checksum_validated: String|nil }
fn build_success_hash(ruby: &Ruby, response: &s3_request::S3Response) -> Result<Value, Error> {
    let hash = RHash::new();

    hash.aset(Symbol::new("status_code"), response.status_code)?;

    // Build headers hash (String keys → String values)
    let headers_hash = RHash::new();
    for (name, value) in &response.headers {
        headers_hash.aset(
            ruby.str_new(name).as_value(),
            ruby.str_new(value).as_value(),
        )?;
    }
    hash.aset(Symbol::new("headers"), headers_hash)?;

    // Body: String or nil
    match &response.body {
        Some(body_bytes) => {
            hash.aset(Symbol::new("body"), ruby.str_from_slice(body_bytes).as_value())?;
        }
        None => {
            hash.aset(Symbol::new("body"), ruby.qnil().as_value())?;
        }
    }

    // Checksum validated: String or nil
    match &response.checksum_validated {
        Some(algo) => {
            hash.aset(Symbol::new("checksum_validated"), ruby.str_new(algo).as_value())?;
        }
        None => {
            hash.aset(Symbol::new("checksum_validated"), ruby.qnil().as_value())?;
        }
    }

    Ok(hash.as_value())
}

/// Build a Ruby Hash from S3 error data.
///
/// Returns: { error: true, error_code: Integer, status_code: Integer, headers: Hash, body: String }
fn build_error_hash(ruby: &Ruby, error: &S3ErrorData) -> Result<Value, Error> {
    let hash = RHash::new();

    hash.aset(Symbol::new("error"), true)?;
    hash.aset(Symbol::new("error_code"), error.error_code)?;
    hash.aset(Symbol::new("status_code"), error.status_code)?;

    // Build headers hash
    let headers_hash = RHash::new();
    for (name, value) in &error.headers {
        headers_hash.aset(
            ruby.str_new(name).as_value(),
            ruby.str_new(value).as_value(),
        )?;
    }
    hash.aset(Symbol::new("headers"), headers_hash)?;

    // Error body
    hash.aset(
        Symbol::new("body"),
        ruby.str_from_slice(&error.body).as_value(),
    )?;

    Ok(hash.as_value())
}

// ---------------------------------------------------------------------------
// RubyS3Client — magnus wrapper
// ---------------------------------------------------------------------------

/// Ruby class `AwsCrt::S3::Client`.
///
/// Each instance owns a CRT S3 client. The `RefCell<Option<...>>` pattern
/// matches `ConnectionPool` in pool.rs — `None` before `initialize` runs,
/// `Some` after.
#[magnus::wrap(class = "AwsCrt::S3::Client", free_immediately, size)]
pub struct RubyS3Client {
    inner: RefCell<Option<S3Client>>,
}

impl Default for RubyS3Client {
    fn default() -> Self {
        Self {
            inner: RefCell::new(None),
        }
    }
}

impl RubyS3Client {
    /// Ruby: `AwsCrt::S3::Client.new(options)`
    ///
    /// options Hash:
    ///   :region (required)
    ///   :access_key_id (required)
    ///   :secret_access_key (required)
    ///   :session_token (optional)
    ///   :throughput_target_gbps (optional, default 10.0)
    ///   :part_size (optional, default 0 = CRT auto-tunes)
    ///   :multipart_upload_threshold (optional, default 0 = CRT auto-tunes)
    ///   :memory_limit_in_bytes (optional, default 0 = CRT default)
    ///   :max_active_connections_override (optional, default 0 = CRT default)
    fn rb_initialize(rb_self: &Self, options: RHash) -> Result<(), Error> {
        let region = hash_get_string_required(&options, "region")?;
        let access_key_id = hash_get_string_required(&options, "access_key_id")?;
        let secret_access_key = hash_get_string_required(&options, "secret_access_key")?;
        let session_token = hash_get_string(&options, "session_token")?;

        let throughput_target_gbps =
            hash_get_f64(&options, "throughput_target_gbps", 10.0)?;
        let part_size = hash_get_u64(&options, "part_size", 0)?;
        let multipart_upload_threshold =
            hash_get_u64(&options, "multipart_upload_threshold", 0)?;
        let memory_limit_in_bytes =
            hash_get_u64(&options, "memory_limit_in_bytes", 0)?;
        let max_active_connections_override =
            hash_get_u32(&options, "max_active_connections_override", 0)?;

        let client_options = S3ClientOptions {
            region,
            access_key_id,
            secret_access_key,
            session_token,
            throughput_target_gbps,
            part_size,
            multipart_upload_threshold,
            memory_limit_in_bytes,
            max_active_connections_override,
        };

        let client = S3Client::new(client_options).map_err(|e| -> Error { e.into() })?;
        *rb_self.inner.borrow_mut() = Some(client);

        Ok(())
    }

    /// Borrow the inner S3Client, returning an error if not initialized.
    fn with_client<F, T>(ruby: &Ruby, rb_self: &typed_data::Obj<Self>, f: F) -> Result<T, Error>
    where
        F: FnOnce(&S3Client) -> Result<T, Error>,
    {
        let inner = rb_self.inner.borrow();
        let client = inner.as_ref().ok_or_else(|| {
            Error::new(
                ruby.exception_runtime_error(),
                "S3 client not initialized",
            )
        })?;
        f(client)
    }

    /// Build a per-request signing config from credentials passed in the params hash.
    ///
    /// The Ruby layer injects `_access_key_id`, `_secret_access_key`, and
    /// `_session_token` into the params hash before calling the native method.
    /// This creates a fresh CRT CredentialsProvider + SigningConfig for each
    /// request, ensuring that temporary credentials are never stale.
    fn build_request_signing_config(
        params: &RHash,
        region: &str,
    ) -> Result<(crate::credentials::CredentialsProvider, Box<crate::signing::SigningConfig>), Error> {
        let access_key_id = hash_get_string_required(params, "_access_key_id")?;
        let secret_access_key = hash_get_string_required(params, "_secret_access_key")?;
        let session_token = hash_get_string(params, "_session_token")?;

        let creds_provider = crate::credentials::CredentialsProvider::new_static(
            &access_key_id,
            &secret_access_key,
            session_token.as_deref(),
        )
        .map_err(|e| -> Error { e.into() })?;

        let signing_config = Box::new(
            crate::signing::SigningConfig::new_s3(region, &creds_provider)
                .map_err(|e| -> Error { e.into() })?,
        );

        Ok((creds_provider, signing_config))
    }

    /// Ruby: `client.get_object(params)` or `client.get_object(params) { |chunk| ... }`
    ///
    /// params Hash:
    ///   :bucket (required)
    ///   :key (required)
    ///   :response_target (optional) — String file path or IO object
    ///   :checksum_mode (optional) — 'ENABLED' to validate
    ///   :on_progress (optional) — Proc called with bytes_transferred
    ///   :_access_key_id (injected by Ruby layer)
    ///   :_secret_access_key (injected by Ruby layer)
    ///   :_session_token (injected by Ruby layer)
    ///
    /// Returns a Ruby Hash (see build_success_hash / build_error_hash).
    fn rb_get_object(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        params: RHash,
    ) -> Result<Value, Error> {
        let bucket = hash_get_string_required(&params, "bucket")?;
        let key = hash_get_string_required(&params, "key")?;
        let response_target = hash_get_value(&params, "response_target")?;
        let checksum_mode = hash_get_string(&params, "checksum_mode")?;
        let _on_progress = hash_get_value(&params, "on_progress")?;

        // Determine body handling mode
        let validate_checksum = checksum_mode.as_deref() == Some("ENABLED");

        // Determine recv_filepath: if response_target is a String, use it as a file path.
        // If it's an IO object or a block is given, we use buffered mode for now
        // (IO streaming and block streaming are handled post-request by the Ruby layer).
        let recv_filepath: Option<String> = match &response_target {
            Some(val) => {
                // Check if it's a String (file path)
                if let Ok(s) = RString::try_convert(*val) {
                    Some(unsafe { s.as_str()?.to_string() })
                } else {
                    // IO object — read body into memory, Ruby layer will handle it
                    None
                }
            }
            None => None,
        };

        // Check if a block was given — if so, we buffer the body and the
        // Ruby layer will yield chunks from the returned body.
        let _block_given = ruby.block_given();

        Self::with_client(ruby, &rb_self, |client| {
            // Build per-request signing config with fresh credentials
            let (_creds_provider, signing_config) =
                Self::build_request_signing_config(&params, client.region())?;

            let options = GetObjectOptions {
                client: client.as_ptr(),
                signing_config: signing_config.as_ptr(),
                bucket: &bucket,
                key: &key,
                region: client.region(),
                recv_filepath: recv_filepath.as_deref(),
                validate_checksum,
            };

            match s3_request::get_object(options) {
                Ok(response) => build_success_hash(ruby, &response),
                Err(error) => build_error_hash(ruby, &error),
            }
        })
    }

    /// Ruby: `client.put_object(params)`
    ///
    /// params Hash:
    ///   :bucket (required)
    ///   :key (required)
    ///   :body (required) — String, File, or IO object
    ///   :content_length (optional) — Integer
    ///   :content_type (optional) — String
    ///   :checksum_algorithm (optional) — 'CRC32', 'CRC32C', 'SHA1', 'SHA256'
    ///   :on_progress (optional) — Proc called with bytes_transferred
    ///   :_access_key_id (injected by Ruby layer)
    ///   :_secret_access_key (injected by Ruby layer)
    ///   :_session_token (injected by Ruby layer)
    ///
    /// Returns a Ruby Hash (see build_success_hash / build_error_hash).
    fn rb_put_object(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        params: RHash,
    ) -> Result<Value, Error> {
        let bucket = hash_get_string_required(&params, "bucket")?;
        let key = hash_get_string_required(&params, "key")?;
        let body_val = hash_get_value(&params, "body")?;
        let content_length = hash_get_optional_u64(&params, "content_length")?;
        let content_type = hash_get_string(&params, "content_type")?;
        let checksum_algorithm_name = hash_get_string(&params, "checksum_algorithm")?;
        let _on_progress = hash_get_value(&params, "on_progress")?;

        // Parse checksum algorithm if provided
        let checksum_algorithm = match &checksum_algorithm_name {
            Some(name) => {
                let algo = s3_request::parse_checksum_algorithm(name).map_err(|_| {
                    Error::new(
                        magnus::exception::arg_error(),
                        format!(
                            "invalid checksum_algorithm '{}': must be CRC32, CRC32C, SHA1, or SHA256",
                            name
                        ),
                    )
                })?;
                Some(algo)
            }
            None => None,
        };

        // Determine body mode: send_filepath (File), buffer (String), or read+buffer (IO)
        let (send_filepath, body_bytes) = match body_val {
            Some(val) => {
                // Try String first
                if let Ok(s) = RString::try_convert(val) {
                    let bytes = unsafe { s.as_slice().to_vec() };
                    (None, Some(bytes))
                } else {
                    // Check if it's a File (responds to :path)
                    let path_sym = Symbol::new("path");
                    let has_path: bool = val
                        .funcall("respond_to?", (path_sym,))
                        .unwrap_or(false);

                    if has_path {
                        // File object — extract path for send_filepath mode
                        let path: String = val.funcall("path", ())?;
                        (Some(path), None)
                    } else {
                        // Generic IO — read contents into memory
                        let contents: RString = val.funcall("read", ())?;
                        let bytes = unsafe { contents.as_slice().to_vec() };
                        (None, Some(bytes))
                    }
                }
            }
            None => (None, None),
        };

        Self::with_client(ruby, &rb_self, |client| {
            // Build per-request signing config with fresh credentials
            let (_creds_provider, signing_config) =
                Self::build_request_signing_config(&params, client.region())?;

            let options = PutObjectOptions {
                client: client.as_ptr(),
                signing_config: signing_config.as_ptr(),
                bucket: &bucket,
                key: &key,
                region: client.region(),
                send_filepath: send_filepath.as_deref(),
                body: body_bytes,
                content_length,
                content_type: content_type.as_deref(),
                checksum_algorithm,
            };

            match s3_request::put_object(options) {
                Ok(response) => build_success_hash(ruby, &response),
                Err(error) => build_error_hash(ruby, &error),
            }
        })
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register the `AwsCrt::S3::Client` class with magnus.
pub fn define_s3_client(
    ruby: &Ruby,
    s3_module: &magnus::RModule,
) -> Result<(), Error> {
    let class = s3_module.define_class("Client", ruby.class_object())?;
    class.define_alloc_func::<RubyS3Client>();
    class.define_method("initialize", method!(RubyS3Client::rb_initialize, 1))?;
    class.define_method("get_object", method!(RubyS3Client::rb_get_object, 1))?;
    class.define_method("put_object", method!(RubyS3Client::rb_put_object, 1))?;

    Ok(())
}
