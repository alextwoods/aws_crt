use magnus::{
    function, prelude::*, scan_args::scan_args, Error, RString, Ruby, TryConvert, Value,
};

// FFI bindings to the AWS CRT checksum C functions.
// These are provided by the pre-built static libraries
// (aws-checksums and aws-c-common).
mod crt {
    /// Opaque allocator type from aws-c-common.
    #[repr(C)]
    pub struct AwsAllocator {
        _private: [u8; 0],
    }

    extern "C" {
        pub fn aws_default_allocator() -> *mut AwsAllocator;
        pub fn aws_checksums_library_init(allocator: *mut AwsAllocator);

        pub fn aws_checksums_crc32_ex(
            input: *const u8,
            length: usize,
            previous_crc32: u32,
        ) -> u32;

        pub fn aws_checksums_crc32c_ex(
            input: *const u8,
            length: usize,
            previous_crc32c: u32,
        ) -> u32;

        pub fn aws_checksums_crc64nvme_ex(
            input: *const u8,
            length: usize,
            previous_crc64: u64,
        ) -> u64;
    }
}

/// Initialize the CRT checksums library. Must be called once before use.
fn init_crt() {
    unsafe {
        let allocator = crt::aws_default_allocator();
        crt::aws_checksums_library_init(allocator);
    }
}

/// Helper to read a Ruby string's bytes without copying.
///
/// SAFETY: Caller must hold the GVL and not store the returned pointer
/// beyond the current native call.
unsafe fn string_bytes(data: RString) -> (*const u8, usize) {
    let slice = data.as_slice();
    (slice.as_ptr(), slice.len())
}

/// Parse an optional previous checksum value from a Ruby Value.
/// Treats nil (or omitted) as 0.
fn parse_previous<T: TryConvert + Default>(val: Option<Value>) -> Result<T, Error> {
    match val {
        Some(v) if v.is_nil() => Ok(T::default()),
        Some(v) => TryConvert::try_convert(v),
        None => Ok(T::default()),
    }
}

/// Compute a CRC32 (Ethernet/gzip) checksum.
///
/// Uses hardware-accelerated instructions when available (SSE4.2, ARM CRC),
/// with fallback to an efficient software implementation.
fn crc32(args: &[Value]) -> Result<u32, Error> {
    let args = scan_args::<(RString,), (Option<Value>,), (), (), (), ()>(args)?;
    let data = args.required.0;
    let prev: u32 = parse_previous(args.optional.0)?;
    unsafe {
        let (ptr, len) = string_bytes(data);
        Ok(crt::aws_checksums_crc32_ex(ptr, len, prev))
    }
}

/// Compute a CRC32C (Castagnoli/iSCSI) checksum.
///
/// Uses hardware-accelerated instructions when available (SSE4.2, ARM CRC),
/// with fallback to an efficient software implementation.
fn crc32c(args: &[Value]) -> Result<u32, Error> {
    let args = scan_args::<(RString,), (Option<Value>,), (), (), (), ()>(args)?;
    let data = args.required.0;
    let prev: u32 = parse_previous(args.optional.0)?;
    unsafe {
        let (ptr, len) = string_bytes(data);
        Ok(crt::aws_checksums_crc32c_ex(ptr, len, prev))
    }
}

/// Compute a CRC64-NVME (CRC64-Rocksoft) checksum.
///
/// Uses hardware-accelerated instructions when available (CLMUL, AVX-512, ARM PMULL),
/// with fallback to an efficient software implementation.
fn crc64nvme(args: &[Value]) -> Result<u64, Error> {
    let args = scan_args::<(RString,), (Option<Value>,), (), (), (), ()>(args)?;
    let data = args.required.0;
    let prev: u64 = parse_previous(args.optional.0)?;
    unsafe {
        let (ptr, len) = string_bytes(data);
        Ok(crt::aws_checksums_crc64nvme_ex(ptr, len, prev))
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    init_crt();

    let module = ruby.define_module("AwsCrt")?;
    let checksums = module.define_module("Checksums")?;

    checksums.define_module_function("crc32", function!(crc32, -1))?;
    checksums.define_module_function("crc32c", function!(crc32c, -1))?;
    checksums.define_module_function("crc64nvme", function!(crc64nvme, -1))?;

    Ok(())
}
