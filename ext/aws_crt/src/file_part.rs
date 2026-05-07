//! Ruby-facing `AwsCrt::Http::FilePart` class.
//!
//! A read-only, Ractor-safe IO object that provides an IO-like interface to a
//! portion of a file on disk. The file is read lazily — bytes are only loaded
//! from disk when `read` is called, with the GVL released during I/O.
//!
//! The object is frozen and Ractor-shareable by default (via `frozen_shareable`
//! on the `TypedData` trait), making it safe to pass between Ractors.
//!
//! This is designed as a drop-in replacement for the `Aws::S3::FilePart` class
//! from the AWS SDK, but with Ractor safety and native performance. It can be
//! used as a request body in the CRT HTTP client (optimized path: file bytes
//! are read directly in Rust without crossing the Ruby boundary).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use magnus::prelude::*;
use magnus::rb_sys::{AsRawValue, FromRawValue};
use magnus::scan_args::scan_args;
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::value::Lazy;
use magnus::{data_type_builder, method, Error, RClass, RString, Ruby, Value};

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn rb_thread_call_without_gvl(
        func: unsafe extern "C" fn(data: *mut std::ffi::c_void) -> *mut std::ffi::c_void,
        data: *mut std::ffi::c_void,
        ubf: *const std::ffi::c_void,
        ubf_data: *const std::ffi::c_void,
    ) -> *mut std::ffi::c_void;
}

// ---------------------------------------------------------------------------
// FilePart struct
// ---------------------------------------------------------------------------

/// Native file-part reader. Ractor-safe, read-only from Ruby.
///
/// Provides an IO-like interface to a byte range within a file.
/// Reads are performed with the GVL released for maximum concurrency.
pub struct FilePart {
    /// Path to the source file.
    source: String,
    /// The byte offset where this part starts in the file.
    offset: u64,
    /// The number of bytes in this part.
    size: u64,
    /// Current read position relative to the start of the part (0-based).
    pos: AtomicUsize,
    /// Cached file content. Loaded lazily on first read.
    /// Once loaded, subsequent reads are served from memory.
    buffer: Mutex<Option<Vec<u8>>>,
}

// SAFETY: All mutable state is behind Mutex/AtomicUsize. No Ruby VALUEs stored.
unsafe impl Send for FilePart {}
unsafe impl Sync for FilePart {}

impl DataTypeFunctions for FilePart {}

unsafe impl TypedData for FilePart {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get::<_, magnus::RModule>("Http")
                .unwrap()
                .const_get("FilePart")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        // NOTE: `free_immediately` is intentionally NOT used here.
        // FilePart#read calls ensure_loaded() which releases the GVL via
        // rb_thread_call_without_gvl for file I/O. While the GVL is released,
        // the GC may run and — if it determines the object is unreachable —
        // would free the Rust struct during sweep. This creates a use-after-
        // free when the GVL-free function returns. Without free_immediately,
        // Ruby defers the free to a safe point after the method has returned.
        static DATA_TYPE: DataType =
            data_type_builder!(FilePart, "AwsCrt::Http::FilePart")
                .frozen_shareable()
                .build();
        &DATA_TYPE
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl FilePart {
    /// Ruby: `FilePart.new(source:, offset:, size:)`
    ///
    /// Creates a new FilePart representing a byte range within a file.
    /// The object is frozen immediately upon creation.
    ///
    /// @param source [String] Path to the source file
    /// @param offset [Integer] Byte offset where this part starts
    /// @param size [Integer] Number of bytes in this part
    fn rb_new(args: &[Value]) -> Result<Value, Error> {
        let parsed = scan_args::<(), (), (), (), magnus::RHash, ()>(args)?;
        let kwargs = magnus::scan_args::get_kwargs::<_, (String, i64, i64), (), ()>(
            parsed.keywords,
            &["source", "offset", "size"],
            &[],
        )?;
        let (source, offset, size) = kwargs.required;

        if offset < 0 {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "offset must be non-negative",
            ));
        }
        if size < 0 {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "size must be non-negative",
            ));
        }

        let obj = typed_data::Obj::wrap(FilePart {
            source,
            offset: offset as u64,
            size: size as u64,
            pos: AtomicUsize::new(0),
            buffer: Mutex::new(None),
        });

        // Freeze the object so it is Ractor-shareable
        unsafe {
            rb_sys::rb_obj_freeze(obj.as_value().as_raw());
        }
        Ok(obj.as_value())
    }

    /// Ensure the buffer is loaded from disk. Returns a reference to the data.
    /// The file read happens with the GVL released.
    fn ensure_loaded(&self) -> Result<(), Error> {
        let mut buf = self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;

        if buf.is_some() {
            return Ok(());
        }

        // Need to drop the lock before calling without GVL, then re-acquire
        drop(buf);

        // Read the file portion without the GVL
        struct ReadData {
            path: std::ffi::CString,
            offset: u64,
            size: u64,
            result: std::result::Result<Vec<u8>, std::io::Error>,
        }

        let path_c = std::ffi::CString::new(self.source.as_str())
            .map_err(|_| Error::new(magnus::exception::arg_error(), "source path contains null byte"))?;

        let mut read_data = ReadData {
            path: path_c,
            offset: self.offset,
            size: self.size,
            result: Ok(Vec::new()),
        };

        unsafe extern "C" fn do_read(ptr: *mut std::ffi::c_void) -> *mut std::ffi::c_void {
            let rd = &mut *(ptr as *mut ReadData);
            rd.result = (|| {
                use std::fs::File;
                use std::io::{Read, Seek, SeekFrom};

                let mut file = File::open(rd.path.to_str().unwrap())?;
                file.seek(SeekFrom::Start(rd.offset))?;

                let mut buffer = vec![0u8; rd.size as usize];
                let mut total_read = 0;
                while total_read < rd.size as usize {
                    let n = file.read(&mut buffer[total_read..])?;
                    if n == 0 {
                        break; // EOF
                    }
                    total_read += n;
                }
                buffer.truncate(total_read);
                Ok(buffer)
            })();
            std::ptr::null_mut()
        }

        unsafe {
            rb_thread_call_without_gvl(
                do_read,
                &mut read_data as *mut ReadData as *mut std::ffi::c_void,
                std::ptr::null(),
                std::ptr::null(),
            );
        }

        let data = read_data.result.map_err(|e| {
            Error::new(
                magnus::exception::io_error(),
                format!("FilePart read failed for '{}': {}", self.source, e),
            )
        })?;

        // Store in the buffer
        let mut buf = self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;
        *buf = Some(data);
        Ok(())
    }

    /// Ruby: `file_part.read(length = nil, outbuf = nil)`
    ///
    /// Matches Ruby IO#read semantics:
    /// - No args: returns all remaining bytes (empty string at EOF)
    /// - With length: returns up to `length` bytes (nil at EOF)
    /// - With length + outbuf: writes into outbuf and returns it
    fn rb_read(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<Value, Error> {
        let parsed = scan_args::<(), (Option<Value>, Option<Value>), (), (), (), ()>(args)?;
        let length_val = parsed.optional.0;
        let outbuf_val = parsed.optional.1;

        // Ensure file content is loaded
        rb_self.ensure_loaded()?;

        let buf_guard = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;
        let buf = buf_guard.as_ref().unwrap();

        let pos = rb_self.pos.load(Ordering::Relaxed);
        let buf_len = buf.len();
        let remaining = buf_len.saturating_sub(pos);

        // Determine if length was provided (and is not nil)
        let length: Option<usize> = match length_val {
            Some(v) if !v.is_nil() => {
                let len: i64 = magnus::TryConvert::try_convert(v)?;
                if len < 0 {
                    return Err(Error::new(
                        magnus::exception::arg_error(),
                        "negative length",
                    ));
                }
                Some(len as usize)
            }
            _ => None,
        };

        match length {
            None => {
                // Read all remaining bytes
                let slice = &buf[pos..];
                rb_self.pos.store(buf_len, Ordering::Relaxed);
                let result = new_binary_string(slice);
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, slice)?;
                    }
                }
                Ok(unsafe { Value::from_raw(result) })
            }
            Some(0) => {
                let result = new_binary_string(&[]);
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, &[])?;
                    }
                }
                Ok(unsafe { Value::from_raw(result) })
            }
            Some(_) if remaining == 0 => {
                // EOF with non-zero length specified → return nil
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, &[])?;
                    }
                }
                Ok(ruby.qnil().as_value())
            }
            Some(n) => {
                let read_len = n.min(remaining);
                let slice = &buf[pos..pos + read_len];
                rb_self.pos.store(pos + read_len, Ordering::Relaxed);
                let result = new_binary_string(slice);
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, slice)?;
                    }
                }
                Ok(unsafe { Value::from_raw(result) })
            }
        }
    }

    /// Ruby: `file_part.rewind`
    ///
    /// Resets the read position to 0 and returns 0.
    fn rb_rewind(rb_self: typed_data::Obj<Self>) -> i64 {
        rb_self.pos.store(0, Ordering::Relaxed);
        0
    }

    /// Ruby: `file_part.size` / `file_part.length`
    ///
    /// Returns the declared size of this file part.
    fn rb_size(rb_self: typed_data::Obj<Self>) -> u64 {
        rb_self.size
    }

    /// Ruby: `file_part.source`
    ///
    /// Returns the source file path.
    fn rb_source(ruby: &Ruby, rb_self: typed_data::Obj<Self>) -> Value {
        ruby.str_new(&rb_self.source).as_value()
    }

    /// Ruby: `file_part.offset`
    ///
    /// Returns the byte offset where this part starts in the source file.
    fn rb_offset(rb_self: typed_data::Obj<Self>) -> u64 {
        rb_self.offset
    }

    /// Ruby: `file_part.eof?`
    ///
    /// Returns true when pos >= size (all bytes have been read).
    fn rb_eof(rb_self: typed_data::Obj<Self>) -> Result<bool, Error> {
        // If buffer is loaded, use actual buffer length; otherwise use declared size
        let buf_guard = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;
        let effective_size = match buf_guard.as_ref() {
            Some(buf) => buf.len(),
            None => rb_self.size as usize,
        };
        let pos = rb_self.pos.load(Ordering::Relaxed);
        Ok(pos >= effective_size)
    }

    /// Ruby: `file_part.pos` / `file_part.tell`
    ///
    /// Returns the current read position (relative to the start of this part).
    fn rb_pos(rb_self: typed_data::Obj<Self>) -> usize {
        rb_self.pos.load(Ordering::Relaxed)
    }

    /// Ruby: `file_part.pos = new_pos`
    ///
    /// Sets the read position. Clamps to size for positive values.
    /// Raises Errno::EINVAL for negative values.
    fn rb_set_pos(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        new_pos: Value,
    ) -> Result<usize, Error> {
        let pos_i64: i64 = magnus::TryConvert::try_convert(new_pos)?;

        if pos_i64 < 0 {
            let errno_module: Value = ruby.eval("Errno::EINVAL")?;
            let exc_class = magnus::ExceptionClass::from_value(errno_module).ok_or_else(|| {
                Error::new(
                    magnus::exception::runtime_error(),
                    "Failed to get Errno::EINVAL",
                )
            })?;
            return Err(Error::new(exc_class, "Invalid argument - negative pos"));
        }

        let new_pos_usize = pos_i64 as usize;
        let clamped = new_pos_usize.min(rb_self.size as usize);
        rb_self.pos.store(clamped, Ordering::Relaxed);
        Ok(clamped)
    }

    /// Ruby: `file_part.closed?`
    ///
    /// Always returns false (the file part is always readable).
    fn rb_closed(&self) -> bool {
        false
    }

    /// Ruby: `file_part.close`
    ///
    /// No-op for compatibility with IO interface.
    fn rb_close(rb_self: typed_data::Obj<Self>) -> Result<Value, Error> {
        let _ = rb_self;
        Ok(unsafe { Value::from_raw(rb_sys::Qnil as rb_sys::VALUE) })
    }

    /// Ruby: `file_part.string`
    ///
    /// Returns the entire part contents as a frozen ASCII-8BIT String.
    fn rb_string(_ruby: &Ruby, rb_self: typed_data::Obj<Self>) -> Result<Value, Error> {
        rb_self.ensure_loaded()?;

        let buf_guard = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;
        let buf = buf_guard.as_ref().unwrap();
        let result = new_binary_string(buf);
        unsafe {
            rb_sys::rb_obj_freeze(result);
        }
        Ok(unsafe { Value::from_raw(result) })
    }

    // ----- Rust-only methods for use by HttpClient/SignedHttpClient -----

    /// Rust-only: read the file part bytes into a Vec<u8>.
    ///
    /// Used by the HTTP client to get body bytes for sending.
    /// Reads from disk with the GVL released if not already cached.
    pub fn read_bytes(rb_self: &typed_data::Obj<Self>) -> Result<Vec<u8>, Error> {
        rb_self.ensure_loaded()?;

        let buf_guard = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "FilePart buffer lock poisoned",
            )
        })?;
        Ok(buf_guard.as_ref().unwrap().clone())
    }

    /// Rust-only: get the source path.
    pub fn source_path(&self) -> &str {
        &self.source
    }

    /// Rust-only: get the byte offset.
    pub fn file_offset(&self) -> u64 {
        self.offset
    }

    /// Rust-only: get the declared size.
    pub fn part_size(&self) -> u64 {
        self.size
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Create a new Ruby String with ASCII-8BIT encoding from a byte slice.
fn new_binary_string(bytes: &[u8]) -> rb_sys::VALUE {
    unsafe {
        let enc = rb_sys::rb_enc_from_index(rb_sys::rb_ascii8bit_encindex());
        rb_sys::rb_enc_str_new(
            bytes.as_ptr() as *const _,
            bytes.len() as std::os::raw::c_long,
            enc,
        )
    }
}

/// Write bytes into an existing Ruby String (outbuf), replacing its content.
/// Sets encoding to ASCII-8BIT.
fn write_into_outbuf(outbuf: Value, bytes: &[u8]) -> Result<(), Error> {
    let rb_str = RString::from_value(outbuf).ok_or_else(|| {
        Error::new(
            magnus::exception::type_error(),
            "outbuf must be a String",
        )
    })?;
    unsafe {
        rb_sys::rb_str_set_len(rb_str.as_raw(), 0);
        rb_sys::rb_str_cat(
            rb_str.as_raw(),
            bytes.as_ptr() as *const _,
            bytes.len() as std::os::raw::c_long,
        );
        let enc_idx = rb_sys::rb_ascii8bit_encindex();
        rb_sys::rb_enc_associate_index(rb_str.as_raw(), enc_idx);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register `AwsCrt::Http::FilePart` with Ruby.
pub fn define_file_part(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let class = http_module.define_class("FilePart", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", magnus::function!(FilePart::rb_new, -1))?;
    class.define_method("read", method!(FilePart::rb_read, -1))?;
    class.define_method("rewind", method!(FilePart::rb_rewind, 0))?;
    class.define_method("size", method!(FilePart::rb_size, 0))?;
    class.define_method("length", method!(FilePart::rb_size, 0))?;
    class.define_method("source", method!(FilePart::rb_source, 0))?;
    class.define_method("offset", method!(FilePart::rb_offset, 0))?;
    class.define_method("eof?", method!(FilePart::rb_eof, 0))?;
    class.define_method("pos", method!(FilePart::rb_pos, 0))?;
    class.define_method("tell", method!(FilePart::rb_pos, 0))?;
    class.define_method("pos=", method!(FilePart::rb_set_pos, 1))?;
    class.define_method("closed?", method!(FilePart::rb_closed, 0))?;
    class.define_method("close", method!(FilePart::rb_close, 0))?;
    class.define_method("string", method!(FilePart::rb_string, 0))?;

    Ok(())
}
