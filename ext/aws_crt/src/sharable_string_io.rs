//! Ruby-facing `AwsCrt::Http::SharableStringIO` class.
//!
//! A read-only, Ractor-safe IO object that buffers HTTP response body bytes
//! in native Rust memory. The CRT event loop writes directly into the buffer
//! via `append()` without crossing the Ruby boundary. Bytes only cross into
//! Ruby when `read` is called, minimizing GVL contention and memory copies.
//!
//! The object is frozen and Ractor-shareable by default (via `frozen_shareable`
//! on the `TypedData` trait), making it safe to pass between Ractors.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

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
// SharableStringIO struct
// ---------------------------------------------------------------------------

/// Native buffer for HTTP response bodies. Ractor-safe, read-only from Ruby.
///
/// The CRT event loop writes directly into `buffer` via the Mutex.
/// Ruby reads are served from `buffer` at the current `pos`.
pub struct SharableStringIO {
    /// The response body bytes. Written by CRT callbacks, read by Ruby.
    /// Arc allows sharing the buffer with CRT callbacks that run without
    /// the GVL. Mutex provides thread-safety for concurrent writes.
    /// After request completion, no more writes occur — reads are
    /// uncontended lock acquisitions in practice.
    buffer: Arc<Mutex<Vec<u8>>>,
    /// Current read position. Atomic for lock-free position tracking.
    pos: AtomicUsize,
}

// SAFETY: All mutable state is behind Mutex/AtomicUsize. No Ruby VALUEs stored.
unsafe impl Send for SharableStringIO {}
unsafe impl Sync for SharableStringIO {}

impl DataTypeFunctions for SharableStringIO {}

unsafe impl TypedData for SharableStringIO {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get::<_, magnus::RModule>("Http")
                .unwrap()
                .const_get("SharableStringIO")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        // NOTE: `free_immediately` is intentionally NOT used here.
        // SharableStringIO methods (write_to_file, write_to_io) release the
        // GVL via rb_thread_call_without_gvl. While the GVL is released, the
        // GC may run and — if it determines the object is unreachable — would
        // free the Rust struct during sweep. This creates a use-after-free
        // when the GVL-free function returns and the method tries to access
        // the (now-freed) TypedData. Without free_immediately, Ruby defers
        // the free to a safe point after the method has returned.
        static DATA_TYPE: DataType =
            data_type_builder!(SharableStringIO, "AwsCrt::Http::SharableStringIO")
                .frozen_shareable()
                .build();
        &DATA_TYPE
    }
}

// ---------------------------------------------------------------------------
// Ruby method implementations
// ---------------------------------------------------------------------------

impl SharableStringIO {
    /// Create a new SharableStringIO with an empty buffer.
    /// The object is frozen immediately upon creation.
    fn rb_new(_ruby: &Ruby) -> Result<Value, Error> {
        let obj = typed_data::Obj::wrap(SharableStringIO {
            buffer: Arc::new(Mutex::new(Vec::new())),
            pos: AtomicUsize::new(0),
        });
        // Freeze the object so it is Ractor-shareable
        unsafe {
            rb_sys::rb_obj_freeze(obj.as_value().as_raw());
        }
        Ok(obj.as_value())
    }

    /// Ruby: `sharable_string_io.read(length = nil, outbuf = nil)`
    ///
    /// Matches Ruby StringIO#read semantics:
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

        let buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;

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
                // If outbuf provided, write into it too
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, slice)?;
                    }
                }
                Ok(unsafe { Value::from_raw(result) })
            }
            Some(0) => {
                // read(0) always returns "" regardless of position (matches StringIO)
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
                // If outbuf provided, clear it
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
                // If outbuf provided, write into it
                if let Some(ob) = outbuf_val {
                    if !ob.is_nil() {
                        write_into_outbuf(ob, slice)?;
                    }
                }
                Ok(unsafe { Value::from_raw(result) })
            }
        }
    }

    /// Ruby: `sharable_string_io.rewind`
    ///
    /// Resets the read position to 0 and returns 0.
    fn rb_rewind(rb_self: typed_data::Obj<Self>) -> i64 {
        rb_self.pos.store(0, Ordering::Relaxed);
        0
    }

    /// Ruby: `sharable_string_io.size` / `sharable_string_io.length`
    ///
    /// Returns the total number of bytes in the buffer.
    fn rb_size(rb_self: typed_data::Obj<Self>) -> Result<usize, Error> {
        let buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;
        Ok(buf.len())
    }

    /// Ruby: `sharable_string_io.string`
    ///
    /// Returns the entire buffer contents as a frozen ASCII-8BIT String.
    fn rb_string(_ruby: &Ruby, rb_self: typed_data::Obj<Self>) -> Result<Value, Error> {
        let buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;
        let result = new_binary_string(&buf);
        // Freeze the returned string
        unsafe {
            rb_sys::rb_obj_freeze(result);
        }
        Ok(unsafe { Value::from_raw(result) })
    }

    /// Ruby: `sharable_string_io.eof?`
    ///
    /// Returns true when pos == buffer.len().
    fn rb_eof(rb_self: typed_data::Obj<Self>) -> Result<bool, Error> {
        let buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;
        let pos = rb_self.pos.load(Ordering::Relaxed);
        Ok(pos >= buf.len())
    }

    /// Ruby: `sharable_string_io.pos` / `sharable_string_io.tell`
    ///
    /// Returns the current read position.
    fn rb_pos(rb_self: typed_data::Obj<Self>) -> usize {
        rb_self.pos.load(Ordering::Relaxed)
    }

    /// Ruby: `sharable_string_io.pos = new_pos`
    ///
    /// Sets the read position. Clamps to buffer size for positive values.
    /// Raises Errno::EINVAL for negative values.
    fn rb_set_pos(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        new_pos: Value,
    ) -> Result<usize, Error> {
        let pos_i64: i64 = magnus::TryConvert::try_convert(new_pos)?;

        if pos_i64 < 0 {
            // Raise Errno::EINVAL
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

        let buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;

        // Clamp to buffer size
        let clamped = new_pos_usize.min(buf.len());
        rb_self.pos.store(clamped, Ordering::Relaxed);
        Ok(clamped)
    }

    /// Ruby: `sharable_string_io.closed?`
    ///
    /// Always returns true (no further writes are possible from Ruby).
    fn rb_closed(&self) -> bool {
        true
    }

    /// Rust-only: append bytes into the buffer.
    ///
    /// Called by CRT callbacks to write response body chunks.
    /// NOT exposed to Ruby.
    pub fn append(rb_self: &typed_data::Obj<Self>, bytes: &[u8]) -> Result<(), Error> {
        let mut buf = rb_self.buffer.lock().map_err(|_| {
            Error::new(
                magnus::exception::runtime_error(),
                "SharableStringIO buffer lock poisoned",
            )
        })?;
        buf.extend_from_slice(bytes);
        Ok(())
    }

    /// Rust-only: create a SharableStringIO with a pre-populated buffer.
    ///
    /// Used by the HttpClient streaming_io path to create a SharableStringIO
    /// from the response body accumulated by the CRT callbacks.
    /// The object is frozen immediately upon creation.
    pub fn new_with_buffer(buffer: Vec<u8>) -> typed_data::Obj<Self> {
        let obj = typed_data::Obj::wrap(SharableStringIO {
            buffer: Arc::new(Mutex::new(buffer)),
            pos: AtomicUsize::new(0),
        });
        // Freeze the object so it is Ractor-shareable
        unsafe {
            rb_sys::rb_obj_freeze(obj.as_value().as_raw());
        }
        obj
    }

    /// Rust-only: get a clone of the buffer Arc.
    ///
    /// Used to pass the buffer to CRT callbacks that run without the GVL.
    /// The callback can write directly into the buffer via the Arc.
    pub fn buffer_arc(&self) -> Arc<Mutex<Vec<u8>>> {
        Arc::clone(&self.buffer)
    }

    /// Ruby: `sharable_string_io.write_to_file(path, offset: 0)`
    ///
    /// Writes the entire buffer directly to a file at the given byte offset.
    /// The write happens in Rust with the GVL released — bytes never cross
    /// into Ruby. This is the fastest path for dumping a response body to disk.
    ///
    /// When a fiber scheduler is active, releasing the GVL allows the scheduler
    /// to run other fibers while the write completes.
    fn rb_write_to_file(
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<usize, Error> {
        let parsed =
            scan_args::<(String,), (), (), (), magnus::RHash, ()>(args)?;
        let path = parsed.required.0;

        // Extract keyword arguments
        let kwargs = magnus::scan_args::get_kwargs::<_, (), (Option<i64>,), ()>(
            parsed.keywords,
            &[],
            &["offset"],
        )?;
        let offset = kwargs.optional.0.unwrap_or(0);
        if offset < 0 {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "offset must be non-negative",
            ));
        }
        let offset = offset as u64;

        // Copy the buffer data while holding the lock (fast memcpy)
        let data = {
            let buf = rb_self.buffer.lock().map_err(|_| {
                Error::new(
                    magnus::exception::runtime_error(),
                    "SharableStringIO buffer lock poisoned",
                )
            })?;
            buf.clone()
        };

        if data.is_empty() {
            return Ok(0);
        }

        // Prepare data for the GVL-free write
        let path_c = std::ffi::CString::new(path.as_str())
            .map_err(|_| Error::new(magnus::exception::arg_error(), "path contains null byte"))?;

        struct WriteData {
            path: std::ffi::CString,
            data: Vec<u8>,
            offset: u64,
            result: std::result::Result<usize, std::io::Error>,
        }

        let mut write_data = WriteData {
            path: path_c,
            data,
            offset,
            result: Ok(0),
        };

        unsafe extern "C" fn do_write(ptr: *mut std::ffi::c_void) -> *mut std::ffi::c_void {
            let wd = &mut *(ptr as *mut WriteData);
            wd.result = (|| {
                use std::fs::OpenOptions;
                use std::io::{Seek, SeekFrom, Write};

                let mut file = OpenOptions::new()
                    .write(true)
                    .create(true)
                    .open(wd.path.to_str().unwrap())?;

                if wd.offset > 0 {
                    file.seek(SeekFrom::Start(wd.offset))?;
                }
                file.write_all(&wd.data)?;
                Ok(wd.data.len())
            })();
            std::ptr::null_mut()
        }

        // Release GVL during the file write — enables fiber scheduler to
        // switch to other fibers while this one blocks on I/O.
        unsafe {
            rb_thread_call_without_gvl(
                do_write,
                &mut write_data as *mut WriteData as *mut std::ffi::c_void,
                std::ptr::null(),
                std::ptr::null(),
            );
        }

        write_data.result.map_err(|e| {
            Error::new(
                magnus::exception::io_error(),
                format!("write_to_file failed: {}", e),
            )
        })
    }

    /// Ruby: `sharable_string_io.write_to_io(io, offset: 0)`
    ///
    /// Writes the entire buffer to an IO object (File, Socket, etc.) using
    /// its file descriptor. The write happens in Rust with the GVL released.
    /// Falls back to calling `io.write` in Ruby if the IO doesn't have a
    /// usable file descriptor (e.g. StringIO).
    ///
    /// The `offset` parameter seeks the destination IO to that position
    /// before writing (only supported for seekable IOs like File).
    fn rb_write_to_io(
        ruby: &Ruby,
        rb_self: typed_data::Obj<Self>,
        args: &[Value],
    ) -> Result<usize, Error> {
        let parsed =
            scan_args::<(Value,), (), (), (), magnus::RHash, ()>(args)?;
        let io_val = parsed.required.0;

        // Extract keyword arguments
        let kwargs = magnus::scan_args::get_kwargs::<_, (), (Option<i64>,), ()>(
            parsed.keywords,
            &[],
            &["offset"],
        )?;
        let offset = kwargs.optional.0.unwrap_or(0);
        if offset < 0 {
            return Err(Error::new(
                magnus::exception::arg_error(),
                "offset must be non-negative",
            ));
        }
        let offset = offset as u64;

        // Copy the buffer data while holding the lock
        let data = {
            let buf = rb_self.buffer.lock().map_err(|_| {
                Error::new(
                    magnus::exception::runtime_error(),
                    "SharableStringIO buffer lock poisoned",
                )
            })?;
            buf.clone()
        };

        if data.is_empty() {
            return Ok(0);
        }

        // Try to get the file descriptor from the IO object via #fileno
        let fd_result: Result<i32, _> = io_val.funcall("fileno", ());

        match fd_result {
            Ok(fd) => {
                // We have a real fd — write directly without GVL
                struct WriteIoData {
                    fd: i32,
                    data: Vec<u8>,
                    offset: u64,
                    result: std::result::Result<usize, std::io::Error>,
                }

                let mut write_data = WriteIoData {
                    fd,
                    data,
                    offset,
                    result: Ok(0),
                };

                unsafe extern "C" fn do_write_fd(
                    ptr: *mut std::ffi::c_void,
                ) -> *mut std::ffi::c_void {
                    let wd = &mut *(ptr as *mut WriteIoData);
                    wd.result = (|| {
                        use std::io::Write;
                        use std::os::fd::FromRawFd;

                        // Borrow the fd without taking ownership (don't close on drop)
                        let file = std::fs::File::from_raw_fd(wd.fd);
                        let mut file = std::mem::ManuallyDrop::new(file);

                        if wd.offset > 0 {
                            use std::io::{Seek, SeekFrom};
                            file.seek(SeekFrom::Start(wd.offset))?;
                        }
                        file.write_all(&wd.data)?;
                        Ok(wd.data.len())
                    })();
                    std::ptr::null_mut()
                }

                unsafe {
                    rb_thread_call_without_gvl(
                        do_write_fd,
                        &mut write_data as *mut WriteIoData as *mut std::ffi::c_void,
                        std::ptr::null(),
                        std::ptr::null(),
                    );
                }

                write_data.result.map_err(|e| {
                    Error::new(
                        magnus::exception::io_error(),
                        format!("write_to_io failed: {}", e),
                    )
                })
            }
            Err(_) => {
                // No fd available (e.g. StringIO) — fall back to Ruby IO#write
                // Seek if offset > 0
                if offset > 0 {
                    let _: Value = io_val.funcall("seek", (offset as i64,))?;
                }
                let rb_str = ruby.str_from_slice(&data);
                let written: usize = io_val.funcall("write", (rb_str,))?;
                Ok(written)
            }
        }
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
    // Replace content: clear then cat
    unsafe {
        rb_sys::rb_str_set_len(rb_str.as_raw(), 0);
        rb_sys::rb_str_cat(
            rb_str.as_raw(),
            bytes.as_ptr() as *const _,
            bytes.len() as std::os::raw::c_long,
        );
        // Set encoding to ASCII-8BIT
        let enc_idx = rb_sys::rb_ascii8bit_encindex();
        rb_sys::rb_enc_associate_index(rb_str.as_raw(), enc_idx);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register `AwsCrt::Http::SharableStringIO` with Ruby.
pub fn define_sharable_string_io(
    ruby: &Ruby,
    http_module: &magnus::RModule,
) -> Result<(), Error> {
    let class = http_module.define_class("SharableStringIO", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", magnus::function!(SharableStringIO::rb_new, 0))?;
    class.define_method("read", method!(SharableStringIO::rb_read, -1))?;
    class.define_method("rewind", method!(SharableStringIO::rb_rewind, 0))?;
    class.define_method("size", method!(SharableStringIO::rb_size, 0))?;
    class.define_method("length", method!(SharableStringIO::rb_size, 0))?;
    class.define_method("string", method!(SharableStringIO::rb_string, 0))?;
    class.define_method("eof?", method!(SharableStringIO::rb_eof, 0))?;
    class.define_method("pos", method!(SharableStringIO::rb_pos, 0))?;
    class.define_method("tell", method!(SharableStringIO::rb_pos, 0))?;
    class.define_method("pos=", method!(SharableStringIO::rb_set_pos, 1))?;
    class.define_method("closed?", method!(SharableStringIO::rb_closed, 0))?;
    class.define_method("write_to_file", method!(SharableStringIO::rb_write_to_file, -1))?;
    class.define_method("write_to_io", method!(SharableStringIO::rb_write_to_io, -1))?;

    Ok(())
}
