//! Ruby-facing `AwsCrt::Http::Response` class.
//!
//! A simple data object representing an HTTP response with status code,
//! headers, body, and optional checksum information. This is a transient
//! response object — it is NOT frozen or Ractor-shareable.
//!
//! ## GC Safety (Ractor + Compaction)
//!
//! This struct stores raw `rb_sys::VALUE` fields that reference Ruby heap
//! objects (headers hash, body string/SharableStringIO, response_target_info
//! hash). These must be properly marked during GC so they are not collected.
//!
//! We use `magnus::gc::Marker::mark` (which calls `rb_gc_mark`) to pin the
//! referenced objects — this prevents Ruby's compacting GC from moving them,
//! ensuring our stored raw VALUE pointers remain valid for the struct's
//! lifetime.
//!
//! **Important**: `free_immediately` is intentionally NOT used here. In a
//! multi-Ractor environment with Ruby 4.0's per-Ractor GC, `free_immediately`
//! can cause the Rust struct to be dropped during a GC sweep phase while
//! another Ractor's GC is concurrently scanning or compacting. This creates
//! a race where the `mark()` callback could be invoked on a partially-freed
//! struct, or where stored VALUEs are accessed after the objects they point
//! to have been moved/freed. Without `free_immediately`, Ruby defers freeing
//! to a safe point where no concurrent GC operations are in progress.

use magnus::prelude::*;
use magnus::rb_sys::FromRawValue;
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::value::Lazy;
use magnus::{data_type_builder, method, Error, RClass, Ruby, Value};

// ---------------------------------------------------------------------------
// HttpResponse struct
// ---------------------------------------------------------------------------

/// Ruby class `AwsCrt::Http::Response`.
///
/// A simple data object holding the HTTP response fields.
/// Ruby VALUEs (headers, body) are stored as raw rb_sys::VALUE and
/// marked/pinned for GC via the `mark()` callback.
pub struct HttpResponse {
    /// The HTTP status code (e.g. 200, 404).
    status_code: i32,
    /// Response headers as Ruby VALUE (RHash with String keys and String values).
    headers: rb_sys::VALUE,
    /// Response body as Ruby VALUE (String, SharableStringIO, or nil).
    body: rb_sys::VALUE,
    /// The checksum algorithm that was matched (e.g. "CRC32"), or nil.
    checksum_algorithm: Option<String>,
    /// The computed checksum value (base64-encoded), or nil.
    computed_checksum: Option<String>,
    /// Response target info as Ruby VALUE (RHash or Qnil).
    /// Describes what response_target action was taken (e.g. {type: :proc},
    /// {type: :file, path: "..."}, or {type: :offset_file, path: "...", offset: N}).
    /// Nil when no response_target was used or when the response was non-2xx.
    response_target_info: rb_sys::VALUE,
}

// SAFETY: The Ruby VALUEs stored here are GC-protected by being reachable
// from the TypedData wrapper (which is itself a Ruby object). The HttpResponse
// is only used transiently within a single request cycle.
unsafe impl Send for HttpResponse {}

impl DataTypeFunctions for HttpResponse {
    fn mark(&self, marker: &magnus::gc::Marker) {
        // Mark (and pin) the stored Ruby VALUEs so GC doesn't collect or
        // move them. Using Marker::mark pins the objects, preventing
        // compaction from relocating them while we hold raw VALUE pointers.
        unsafe {
            marker.mark(Value::from_raw(self.headers));
            marker.mark(Value::from_raw(self.body));
            marker.mark(Value::from_raw(self.response_target_info));
        }
    }
}

unsafe impl TypedData for HttpResponse {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get::<_, magnus::RModule>("Http")
                .unwrap()
                .const_get("Response")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        static DATA_TYPE: DataType =
            data_type_builder!(HttpResponse, "AwsCrt::Http::Response")
                .mark()
                .build();
        &DATA_TYPE
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl HttpResponse {
    /// Create a new HttpResponse from Rust data.
    ///
    /// This is NOT exposed to Ruby — it's called from http_client.rs.
    pub fn new_from_parts(
        status_code: i32,
        headers: rb_sys::VALUE,
        body: rb_sys::VALUE,
        checksum_algorithm: Option<String>,
        computed_checksum: Option<String>,
        response_target_info: rb_sys::VALUE,
    ) -> typed_data::Obj<Self> {
        typed_data::Obj::wrap(HttpResponse {
            status_code,
            headers,
            body,
            checksum_algorithm,
            computed_checksum,
            response_target_info,
        })
    }

    /// Ruby: `response.status_code` → Integer
    fn rb_status_code(&self) -> i32 {
        self.status_code
    }

    /// Ruby: `response.headers` → Hash of {name => value}
    fn rb_headers(&self) -> Value {
        unsafe { Value::from_raw(self.headers) }
    }

    /// Ruby: `response.body` → String, SharableStringIO, or nil
    fn rb_body(&self) -> Value {
        unsafe { Value::from_raw(self.body) }
    }

    /// Ruby: `response.checksum_algorithm` → String or nil
    fn rb_checksum_algorithm(ruby: &Ruby, rb_self: typed_data::Obj<Self>) -> Value {
        match &rb_self.checksum_algorithm {
            Some(alg) => ruby.str_new(alg).as_value(),
            None => ruby.qnil().as_value(),
        }
    }

    /// Ruby: `response.computed_checksum` → String or nil
    fn rb_computed_checksum(ruby: &Ruby, rb_self: typed_data::Obj<Self>) -> Value {
        match &rb_self.computed_checksum {
            Some(cs) => ruby.str_new(cs).as_value(),
            None => ruby.qnil().as_value(),
        }
    }

    /// Ruby: `response.response_target_info` → Hash or nil
    ///
    /// Returns a Hash describing the response target action taken, or nil if
    /// no response target was used or the response was non-2xx.
    fn rb_response_target_info(&self) -> Value {
        unsafe { Value::from_raw(self.response_target_info) }
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register `AwsCrt::Http::Response` with Ruby.
pub fn define_http_response(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let class = http_module.define_class("Response", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_method("status_code", method!(HttpResponse::rb_status_code, 0))?;
    class.define_method("headers", method!(HttpResponse::rb_headers, 0))?;
    class.define_method("body", method!(HttpResponse::rb_body, 0))?;
    class.define_method("checksum_algorithm", method!(HttpResponse::rb_checksum_algorithm, 0))?;
    class.define_method("computed_checksum", method!(HttpResponse::rb_computed_checksum, 0))?;
    class.define_method("response_target_info", method!(HttpResponse::rb_response_target_info, 0))?;

    Ok(())
}
