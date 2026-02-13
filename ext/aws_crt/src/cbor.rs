use magnus::{
    exception, function, method,
    prelude::*,
    rb_sys::{AsRawValue, FromRawValue},
    typed_data, Class, Error, ExceptionClass, Module, RArray, RString, Ruby, Symbol, TryConvert,
    Value,
};
use rb_sys::{
    rb_ary_push, rb_enc_get_index, rb_enc_str_new, rb_float_value,
    rb_hash_aset, rb_hash_foreach, rb_hash_size, rb_obj_is_kind_of, rb_sym2str,
    ruby_value_type, VALUE,
};

extern "C" {
    fn rb_float_new(d: f64) -> VALUE;
}
use std::cell::{Cell, RefCell};
use std::ffi::c_int;
use std::os::raw::c_long;

// ---------------------------------------------------------------------------
// Cached class references – set once during init(), read on every encode/decode
// ---------------------------------------------------------------------------

static mut TAGGED_CLASS: VALUE = 0;
static mut TIME_CLASS: VALUE = 0;
static mut BIGDECIMAL_CLASS: VALUE = 0;
static mut BIGDECIMAL_LOADED: bool = false;
static mut UTF8_ENCINDEX: c_int = 0;
static mut BINARY_ENCINDEX: c_int = 0;

/// Initialize cached class references. Called once from `init()`.
unsafe fn cache_classes(ruby: &Ruby) {
    let time_val: Value = ruby.eval("Time").unwrap();
    TIME_CLASS = time_val.as_raw();

    let bd_val: Value = ruby
        .eval("defined?(BigDecimal) ? BigDecimal : nil")
        .unwrap();
    if !bd_val.is_nil() {
        BIGDECIMAL_CLASS = bd_val.as_raw();
        BIGDECIMAL_LOADED = true;
    }

    UTF8_ENCINDEX = rb_sys::rb_utf8_encindex();
    BINARY_ENCINDEX = rb_sys::rb_ascii8bit_encindex();
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------

fn get_cbor_module(ruby: &Ruby) -> magnus::RModule {
    ruby.class_object()
        .const_get::<_, magnus::RModule>("AwsCrt")
        .unwrap()
        .const_get::<_, magnus::RModule>("Cbor")
        .unwrap()
}

fn cbor_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("Error")
        .unwrap()
}

fn out_of_bytes_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("OutOfBytesError")
        .unwrap()
}

fn extra_bytes_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("ExtraBytesError")
        .unwrap()
}

fn unknown_type_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("UnknownTypeError")
        .unwrap()
}

fn unexpected_additional_info_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("UnexpectedAdditionalInformationError")
        .unwrap()
}

fn unexpected_break_code_error(ruby: &Ruby) -> ExceptionClass {
    get_cbor_module(ruby)
        .const_get::<_, ExceptionClass>("UnexpectedBreakCodeError")
        .unwrap()
}

// ---------------------------------------------------------------------------
// Raw Ruby helpers
// ---------------------------------------------------------------------------

#[inline(always)]
fn raw_type(val: VALUE) -> ruby_value_type {
    unsafe { rb_sys::RB_TYPE(val) }
}

#[inline(always)]
fn raw_is_kind_of(val: VALUE, klass: VALUE) -> bool {
    unsafe { rb_obj_is_kind_of(val, klass) != rb_sys::Qfalse as VALUE }
}

#[inline(always)]
unsafe fn float_to_f64(val: VALUE) -> f64 {
    rb_float_value(val)
}

#[inline(always)]
unsafe fn rstring_ptr_len(val: VALUE) -> (*const u8, usize) {
    let ptr = rb_sys::RSTRING_PTR(val) as *const u8;
    let len = rb_sys::RSTRING_LEN(val) as usize;
    (ptr, len)
}

#[inline(always)]
unsafe fn new_encoded_string(bytes: &[u8], enc_index: c_int) -> VALUE {
    rb_enc_str_new(
        bytes.as_ptr() as *const _,
        bytes.len() as c_long,
        rb_sys::rb_enc_from_index(enc_index),
    )
}

#[inline(always)]
unsafe fn string_enc_index(val: VALUE) -> c_int {
    rb_enc_get_index(val)
}

/// Create a Ruby Fixnum from an i64 without going through magnus.
#[inline(always)]
fn fixnum_val(v: i64) -> VALUE {
    unsafe { rb_sys::LONG2FIX(v as c_long) as VALUE }
}

// ---------------------------------------------------------------------------
// CBOR constants
// ---------------------------------------------------------------------------

const MAJOR_UNSIGNED: u8 = 0x00;
const MAJOR_NEGATIVE: u8 = 0x20;
const MAJOR_BYTES: u8 = 0x40;
const MAJOR_TEXT: u8 = 0x60;
const MAJOR_ARRAY: u8 = 0x80;
const MAJOR_MAP: u8 = 0xa0;
const MAJOR_TAG: u8 = 0xc0;
const MAJOR_SIMPLE: u8 = 0xe0;

const FLOAT_MARKER: u8 = 0xfa;
const DOUBLE_MARKER: u8 = 0xfb;

const TAG_EPOCH: u64 = 1;
const TAG_BIGNUM: u64 = 2;
const TAG_NEG_BIGNUM: u64 = 3;
const TAG_BIGDEC: u64 = 4;

// ---------------------------------------------------------------------------
// Hash iteration context
// ---------------------------------------------------------------------------

struct HashIterCtx {
    buf: *mut Vec<u8>,
    error: Option<Error>,
}

unsafe extern "C" fn hash_foreach_cb(key: VALUE, val: VALUE, ctx_ptr: VALUE) -> c_int {
    let ctx = &mut *(ctx_ptr as *mut HashIterCtx);
    let ruby = Ruby::get_unchecked();
    let buf = &mut *ctx.buf;
    if let Err(e) = encode_value(&ruby, buf, key) {
        ctx.error = Some(e);
        return 1;
    }
    if let Err(e) = encode_value(&ruby, buf, val) {
        ctx.error = Some(e);
        return 1;
    }
    0
}

// ---------------------------------------------------------------------------
// Core CBOR encoding (free functions — no struct overhead)
// ---------------------------------------------------------------------------

#[inline(always)]
fn write_head(buf: &mut Vec<u8>, major: u8, value: u64) {
    match value {
        0..=23 => buf.push(major | value as u8),
        24..=0xff => {
            buf.push(major | 24);
            buf.push(value as u8);
        }
        0x100..=0xffff => {
            buf.push(major | 25);
            buf.extend_from_slice(&(value as u16).to_be_bytes());
        }
        0x1_0000..=0xffff_ffff => {
            buf.push(major | 26);
            buf.extend_from_slice(&(value as u32).to_be_bytes());
        }
        _ => {
            buf.push(major | 27);
            buf.extend_from_slice(&value.to_be_bytes());
        }
    }
}

#[inline(always)]
fn encode_integer(buf: &mut Vec<u8>, val: i128) {
    if val < 0 {
        write_head(buf, MAJOR_NEGATIVE, (-1 - val) as u64);
    } else {
        write_head(buf, MAJOR_UNSIGNED, val as u64);
    }
}

#[inline(always)]
fn encode_text(buf: &mut Vec<u8>, bytes: &[u8]) {
    write_head(buf, MAJOR_TEXT, bytes.len() as u64);
    buf.extend_from_slice(bytes);
}

#[inline(always)]
fn encode_double(buf: &mut Vec<u8>, val: f64) {
    buf.push(DOUBLE_MARKER);
    buf.extend_from_slice(&val.to_be_bytes());
}

#[inline(always)]
fn encode_auto_float(buf: &mut Vec<u8>, val: f64) {
    if val.is_nan() {
        buf.push(FLOAT_MARKER);
        buf.extend_from_slice(&(val as f32).to_be_bytes());
    } else {
        let single = val as f32;
        if single as f64 == val {
            buf.push(FLOAT_MARKER);
            buf.extend_from_slice(&single.to_be_bytes());
        } else {
            buf.push(DOUBLE_MARKER);
            buf.extend_from_slice(&val.to_be_bytes());
        }
    }
}

fn encode_ruby_bignum(ruby: &Ruby, buf: &mut Vec<u8>, raw: VALUE) -> Result<(), Error> {
    let value = unsafe { Value::from_raw(raw) };
    if let Ok(v) = i64::try_convert(value) {
        encode_integer(buf, v as i128);
        return Ok(());
    }
    if let Ok(v) = u64::try_convert(value) {
        write_head(buf, MAJOR_UNSIGNED, v);
        return Ok(());
    }
    let negative: bool = value.funcall("negative?", ())?;
    let magnitude: Value = if negative {
        let neg_one = ruby.into_value(-1i64);
        neg_one.funcall("-", (value,))?
    } else {
        value
    };
    let bit_length: u64 = magnitude.funcall("bit_length", ())?;
    let byte_count = (bit_length + 7) / 8;
    let mut mag_bytes = Vec::with_capacity(byte_count as usize);
    for i in (0..byte_count).rev() {
        let shifted: Value = magnitude.funcall(">>", (i * 8,))?;
        let byte_val: u64 = shifted.funcall("&", (0xffu64,))?;
        mag_bytes.push(byte_val as u8);
    }
    let tag = if negative { TAG_NEG_BIGNUM } else { TAG_BIGNUM };
    write_head(buf, MAJOR_TAG, tag);
    write_head(buf, MAJOR_BYTES, mag_bytes.len() as u64);
    buf.extend_from_slice(&mag_bytes);
    Ok(())
}

fn encode_big_decimal(_ruby: &Ruby, buf: &mut Vec<u8>, value: Value) -> Result<(), Error> {
    let infinite: Value = value.funcall("infinite?", ())?;
    if !infinite.is_nil() {
        let inf_val: i64 = TryConvert::try_convert(infinite)?;
        encode_auto_float(
            buf,
            if inf_val >= 0 { f64::INFINITY } else { f64::NEG_INFINITY },
        );
        return Ok(());
    }
    let nan: bool = value.funcall("nan?", ())?;
    if nan {
        encode_auto_float(buf, f64::NAN);
        return Ok(());
    }
    write_head(buf, MAJOR_TAG, TAG_BIGDEC);
    let parts: RArray = value.funcall("split", ())?;
    let sign: i64 = TryConvert::try_convert(parts.entry(0)?)?;
    let digits_str: String = TryConvert::try_convert(parts.entry(1)?)?;
    let exp: i64 = TryConvert::try_convert(parts.entry(3)?)?;
    let cbor_exp = exp - digits_str.len() as i64;
    let mantissa: i128 = digits_str.parse::<i128>().unwrap_or(0) * sign as i128;
    write_head(buf, MAJOR_ARRAY, 2);
    encode_integer(buf, cbor_exp as i128);
    encode_integer(buf, mantissa);
    Ok(())
}

/// Main recursive encoder — operates on raw VALUEs, writes to a Vec<u8>.
fn encode_value(ruby: &Ruby, buf: &mut Vec<u8>, raw: VALUE) -> Result<(), Error> {
    // Immediate values — no C API call needed
    if raw == rb_sys::Qnil as VALUE {
        write_head(buf, MAJOR_SIMPLE, 22);
        return Ok(());
    }
    if raw == rb_sys::Qtrue as VALUE {
        write_head(buf, MAJOR_SIMPLE, 21);
        return Ok(());
    }
    if raw == rb_sys::Qfalse as VALUE {
        write_head(buf, MAJOR_SIMPLE, 20);
        return Ok(());
    }
    if rb_sys::FIXNUM_P(raw) {
        let v = unsafe { rb_sys::FIX2LONG(raw) } as i64;
        encode_integer(buf, v as i128);
        return Ok(());
    }
    if rb_sys::FLONUM_P(raw) {
        let f = unsafe { float_to_f64(raw) };
        encode_auto_float(buf, f);
        return Ok(());
    }

    let typ = raw_type(raw);

    match typ {
        ruby_value_type::RUBY_T_STRING => unsafe {
            let (ptr, len) = rstring_ptr_len(raw);
            let enc_idx = string_enc_index(raw);
            let bytes = std::slice::from_raw_parts(ptr, len);
            if enc_idx == BINARY_ENCINDEX {
                write_head(buf, MAJOR_BYTES, len as u64);
            } else {
                write_head(buf, MAJOR_TEXT, len as u64);
            }
            buf.extend_from_slice(bytes);
            Ok(())
        },

        ruby_value_type::RUBY_T_ARRAY => {
            let len = unsafe { rb_sys::RARRAY_LEN(raw) as usize };
            write_head(buf, MAJOR_ARRAY, len as u64);
            // Use RARRAY_CONST_PTR for direct pointer access when possible
            let ptr = unsafe { rb_sys::RARRAY_CONST_PTR(raw) };
            for i in 0..len {
                let elem = unsafe { *ptr.add(i) };
                encode_value(ruby, buf, elem)?;
            }
            Ok(())
        }

        ruby_value_type::RUBY_T_HASH => {
            let size_val = unsafe { rb_hash_size(raw) };
            let size = unsafe { rb_sys::FIX2LONG(size_val) } as u64;
            write_head(buf, MAJOR_MAP, size);

            let mut ctx = HashIterCtx {
                buf: buf as *mut Vec<u8>,
                error: None,
            };
            unsafe {
                rb_hash_foreach(
                    raw,
                    Some(hash_foreach_cb),
                    &mut ctx as *mut HashIterCtx as VALUE,
                );
            }
            if let Some(e) = ctx.error {
                return Err(e);
            }
            Ok(())
        }

        ruby_value_type::RUBY_T_FLOAT => {
            let f = unsafe { float_to_f64(raw) };
            encode_auto_float(buf, f);
            Ok(())
        }

        ruby_value_type::RUBY_T_SYMBOL => {
            let str_val = unsafe { rb_sym2str(raw) };
            let (ptr, len) = unsafe { rstring_ptr_len(str_val) };
            let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
            encode_text(buf, bytes);
            Ok(())
        }

        ruby_value_type::RUBY_T_BIGNUM => encode_ruby_bignum(ruby, buf, raw),

        ruby_value_type::RUBY_T_STRUCT => {
            let value = unsafe { Value::from_raw(raw) };
            let class_name: String =
                value.funcall("class", ()).and_then(|c: Value| c.funcall("to_s", ()))?;
            Err(Error::new(
                unknown_type_error(ruby),
                format!("Unable to encode {}", class_name),
            ))
        }

        ruby_value_type::RUBY_T_DATA => {
            // Check Tagged first (it's also T_DATA via magnus::wrap)
            let tagged_class = unsafe { TAGGED_CLASS };
            if tagged_class != 0 && raw_is_kind_of(raw, tagged_class) {
                let value = unsafe { Value::from_raw(raw) };
                let tag: u64 = value.funcall("tag", ())?;
                let inner: Value = value.funcall("value", ())?;
                write_head(buf, MAJOR_TAG, tag);
                return encode_value(ruby, buf, inner.as_raw());
            }

            let time_class = unsafe { TIME_CLASS };
            if time_class != 0 && raw_is_kind_of(raw, time_class) {
                let value = unsafe { Value::from_raw(raw) };
                write_head(buf, MAJOR_TAG, TAG_EPOCH);
                let epoch: f64 = value.funcall("to_f", ())?;
                encode_double(buf, epoch);
                return Ok(());
            }

            let bd_class = unsafe {
                if BIGDECIMAL_LOADED {
                    BIGDECIMAL_CLASS
                } else {
                    let bd_val: Value = ruby
                        .eval("defined?(BigDecimal) ? BigDecimal : nil")
                        .unwrap_or_else(|_| ruby.qnil().as_value());
                    if !bd_val.is_nil() {
                        BIGDECIMAL_CLASS = bd_val.as_raw();
                        BIGDECIMAL_LOADED = true;
                        BIGDECIMAL_CLASS
                    } else {
                        0
                    }
                }
            };
            if bd_class != 0 && raw_is_kind_of(raw, bd_class) {
                let value = unsafe { Value::from_raw(raw) };
                return encode_big_decimal(ruby, buf, value);
            }

            let value = unsafe { Value::from_raw(raw) };
            let class_name: String =
                value.funcall("class", ()).and_then(|c: Value| c.funcall("to_s", ()))?;
            Err(Error::new(
                unknown_type_error(ruby),
                format!("Unable to encode {}", class_name),
            ))
        }

        _ => {
            let value = unsafe { Value::from_raw(raw) };
            let class_name: String =
                value.funcall("class", ()).and_then(|c: Value| c.funcall("to_s", ()))?;
            Err(Error::new(
                unknown_type_error(ruby),
                format!("Unable to encode {}", class_name),
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Core CBOR decoding (free functions — no struct overhead)
// ---------------------------------------------------------------------------

#[inline(always)]
fn dec_peek(ruby: &Ruby, data: &[u8], pos: usize) -> Result<u8, Error> {
    if pos >= data.len() {
        return Err(Error::new(
            out_of_bytes_error(ruby),
            format!(
                "Out of bytes. Trying to read 1 bytes but buffer contains only {}",
                data.len() as isize - pos as isize
            ),
        ));
    }
    Ok(data[pos])
}

#[inline(always)]
fn dec_take<'a>(
    ruby: &Ruby,
    data: &'a [u8],
    pos: &mut usize,
    n: usize,
) -> Result<&'a [u8], Error> {
    let new_pos = *pos + n;
    if new_pos > data.len() {
        return Err(Error::new(
            out_of_bytes_error(ruby),
            format!(
                "Out of bytes. Trying to read {} bytes but buffer contains only {}",
                n,
                data.len() as isize - *pos as isize
            ),
        ));
    }
    let slice = &data[*pos..new_pos];
    *pos = new_pos;
    Ok(slice)
}

#[inline(always)]
fn dec_read_info(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<(u8, u8), Error> {
    let b = dec_take(ruby, data, pos, 1)?[0];
    Ok((b >> 5, b & 0x1f))
}

#[inline(always)]
fn dec_read_count(ruby: &Ruby, data: &[u8], pos: &mut usize, ai: u8) -> Result<u64, Error> {
    match ai {
        0..=23 => Ok(ai as u64),
        24 => Ok(dec_take(ruby, data, pos, 1)?[0] as u64),
        25 => {
            let b = dec_take(ruby, data, pos, 2)?;
            Ok(u16::from_be_bytes([b[0], b[1]]) as u64)
        }
        26 => {
            let b = dec_take(ruby, data, pos, 4)?;
            Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as u64)
        }
        27 => {
            let b = dec_take(ruby, data, pos, 8)?;
            Ok(u64::from_be_bytes([
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            ]))
        }
        _ => Err(Error::new(
            unexpected_additional_info_error(ruby),
            format!("Unexpected additional information: {}", ai),
        )),
    }
}

fn decode_value(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let p = *pos;
    if p >= data.len() {
        return Err(Error::new(
            out_of_bytes_error(ruby),
            format!(
                "Out of bytes. Trying to read 1 bytes but buffer contains only {}",
                data.len() as isize - p as isize
            ),
        ));
    }
    let ib = data[p];
    let major = ib >> 5;
    let add_info = ib & 0x1f;

    match major {
        // Fast path for small unsigned integers (0..23) — very common
        0 if add_info < 24 => {
            *pos = p + 1;
            Ok(fixnum_val(add_info as i64))
        }
        // Fast path for small negative integers (-1..-24)
        1 if add_info < 24 => {
            *pos = p + 1;
            Ok(fixnum_val(-1 - add_info as i64))
        }
        0 | 1 => decode_integer_raw(ruby, data, pos),
        2 if add_info == 31 => decode_indef_binary(ruby, data, pos),
        2 => decode_binary_raw(ruby, data, pos),
        3 if add_info == 31 => decode_indef_text(ruby, data, pos),
        3 => decode_text_raw(ruby, data, pos),
        4 if add_info == 31 => decode_indef_array(ruby, data, pos),
        4 => decode_array_raw(ruby, data, pos),
        5 if add_info == 31 => decode_indef_map(ruby, data, pos),
        5 => decode_map_raw(ruby, data, pos),
        6 => decode_tag_raw(ruby, data, pos),
        7 => match add_info {
            20 => {
                *pos = p + 1;
                Ok(rb_sys::Qfalse as VALUE)
            }
            21 => {
                *pos = p + 1;
                Ok(rb_sys::Qtrue as VALUE)
            }
            22 => {
                *pos = p + 1;
                Ok(rb_sys::Qnil as VALUE)
            }
            23 => {
                *pos = p + 1;
                Ok(Symbol::new("undefined").as_value().as_raw())
            }
            25 => decode_half_raw(ruby, data, pos),
            26 => {
                let start = p + 1;
                let end = start + 4;
                if end > data.len() {
                    return Err(Error::new(
                        out_of_bytes_error(ruby),
                        format!(
                            "Out of bytes. Trying to read 4 bytes but buffer contains only {}",
                            data.len() as isize - start as isize
                        ),
                    ));
                }
                let f = f32::from_be_bytes([data[start], data[start+1], data[start+2], data[start+3]]);
                *pos = end;
                Ok(unsafe { rb_float_new(f as f64) })
            }
            27 => {
                let start = p + 1;
                let end = start + 8;
                if end > data.len() {
                    return Err(Error::new(
                        out_of_bytes_error(ruby),
                        format!(
                            "Out of bytes. Trying to read 8 bytes but buffer contains only {}",
                            data.len() as isize - start as isize
                        ),
                    ));
                }
                let f = f64::from_be_bytes([
                    data[start], data[start+1], data[start+2], data[start+3],
                    data[start+4], data[start+5], data[start+6], data[start+7],
                ]);
                *pos = end;
                Ok(unsafe { rb_float_new(f) })
            }
            31 => Err(Error::new(
                unexpected_break_code_error(ruby),
                "Unexpected break stop code",
            )),
            _ => {
                *pos = p + 1;
                Err(Error::new(
                    cbor_error(ruby),
                    format!("Undefined reserved additional information: {}", add_info),
                ))
            }
        },
        _ => unreachable!(),
    }
}

#[inline]
fn decode_integer_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (major, ai) = dec_read_info(ruby, data, pos)?;
    let val = dec_read_count(ruby, data, pos, ai)?;
    match major {
        0 => {
            if val <= i64::MAX as u64 {
                // Use LONG2FIX for fixnum range, avoids magnus overhead
                let v = val as i64;
                if rb_sys::FIXABLE(v as c_long) {
                    Ok(fixnum_val(v))
                } else {
                    Ok(ruby.into_value(v).as_raw())
                }
            } else {
                Ok(ruby.into_value(val).as_raw())
            }
        }
        1 => {
            if val <= i64::MAX as u64 {
                let v = -1i64 - val as i64;
                if rb_sys::FIXABLE(v as c_long) {
                    Ok(fixnum_val(v))
                } else {
                    Ok(ruby.into_value(v).as_raw())
                }
            } else {
                let rv: Value = ruby.into_value(val);
                let neg_one: Value = ruby.into_value(-1i64);
                Ok(neg_one.funcall::<_, _, Value>("-", (rv,))?.as_raw())
            }
        }
        _ => Err(Error::new(
            cbor_error(ruby),
            format!("Expected Integer (0,1) got major type: {}", major),
        )),
    }
}

#[inline]
fn decode_binary_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)? as usize;
    let bytes = dec_take(ruby, data, pos, len)?;
    Ok(unsafe { new_encoded_string(bytes, BINARY_ENCINDEX) })
}

#[inline]
fn decode_text_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    // Fast path for short strings (ai < 24)
    let p = *pos;
    if p < data.len() {
        let ai = data[p] & 0x1f;
        if ai < 24 {
            let len = ai as usize;
            let start = p + 1;
            let end = start + len;
            if end <= data.len() {
                *pos = end;
                return Ok(unsafe { new_encoded_string(&data[start..end], UTF8_ENCINDEX) });
            }
        }
    }
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)? as usize;
    let bytes = dec_take(ruby, data, pos, len)?;
    Ok(unsafe { new_encoded_string(bytes, UTF8_ENCINDEX) })
}

fn decode_array_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)? as usize;
    let arr = unsafe { rb_sys::rb_ary_new_capa(len as c_long) };
    for _ in 0..len {
        let item = decode_value(ruby, data, pos)?;
        unsafe { rb_ary_push(arr, item) };
    }
    Ok(arr)
}

fn decode_map_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)? as usize;
    let hash = unsafe { rb_sys::rb_hash_new_capa(len as c_long) };
    for _ in 0..len {
        // Inline key decode: most keys are short text (major 3, ai < 24)
        let key;
        let p = *pos;
        if p < data.len() {
            let ib = data[p];
            let kai = ib & 0x1f;
            if (ib >> 5) == 3 && kai < 24 {
                let slen = kai as usize;
                let start = p + 1;
                let end = start + slen;
                if end <= data.len() {
                    *pos = end;
                    key = unsafe {
                        new_encoded_string(&data[start..end], UTF8_ENCINDEX)
                    };
                } else {
                    key = decode_text_raw(ruby, data, pos)?;
                }
            } else {
                key = decode_text_raw(ruby, data, pos)?;
            }
        } else {
            key = decode_text_raw(ruby, data, pos)?;
        }
        let val = decode_value(ruby, data, pos)?;
        unsafe { rb_hash_aset(hash, key, val) };
    }
    Ok(hash)
}

fn decode_indef_array(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    *pos += 1; // skip initial byte (0x9f)
    let arr = unsafe { rb_sys::rb_ary_new() };
    loop {
        let ib = dec_peek(ruby, data, *pos)?;
        if ib == 0xff {
            *pos += 1;
            break;
        }
        let item = decode_value(ruby, data, pos)?;
        unsafe { rb_ary_push(arr, item) };
    }
    Ok(arr)
}

fn decode_indef_map(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    *pos += 1;
    let hash = unsafe { rb_sys::rb_hash_new() };
    loop {
        let ib = dec_peek(ruby, data, *pos)?;
        if ib == 0xff {
            *pos += 1;
            break;
        }
        // Inline short text key decode (major 3, ai < 24)
        let key;
        let p = *pos;
        if p < data.len() {
            let b = data[p];
            let kai = b & 0x1f;
            if (b >> 5) == 3 && kai < 24 {
                let slen = kai as usize;
                let start = p + 1;
                let end = start + slen;
                if end <= data.len() {
                    *pos = end;
                    key = unsafe { new_encoded_string(&data[start..end], UTF8_ENCINDEX) };
                } else {
                    key = decode_text_raw(ruby, data, pos)?;
                }
            } else {
                key = decode_text_raw(ruby, data, pos)?;
            }
        } else {
            key = decode_text_raw(ruby, data, pos)?;
        }
        let val = decode_value(ruby, data, pos)?;
        unsafe { rb_hash_aset(hash, key, val) };
    }
    Ok(hash)
}

fn decode_indef_binary(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    *pos += 1;
    let mut result = Vec::new();
    loop {
        let ib = dec_peek(ruby, data, *pos)?;
        if ib == 0xff {
            *pos += 1;
            break;
        }
        let (_mt, ai) = dec_read_info(ruby, data, pos)?;
        let len = dec_read_count(ruby, data, pos, ai)? as usize;
        result.extend_from_slice(dec_take(ruby, data, pos, len)?);
    }
    Ok(unsafe { new_encoded_string(&result, BINARY_ENCINDEX) })
}

fn decode_indef_text(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    *pos += 1;
    let mut result = Vec::new();
    loop {
        let ib = dec_peek(ruby, data, *pos)?;
        if ib == 0xff {
            *pos += 1;
            break;
        }
        let (_mt, ai) = dec_read_info(ruby, data, pos)?;
        let len = dec_read_count(ruby, data, pos, ai)? as usize;
        result.extend_from_slice(dec_take(ruby, data, pos, len)?);
    }
    Ok(unsafe { new_encoded_string(&result, UTF8_ENCINDEX) })
}

fn decode_tag_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let tag = dec_read_count(ruby, data, pos, ai)?;
    match tag {
        TAG_EPOCH => {
            let item = decode_value(ruby, data, pos)?;
            let item_val = unsafe { Value::from_raw(item) };
            let time_class = unsafe { Value::from_raw(TIME_CLASS) };
            Ok(time_class.funcall::<_, _, Value>("at", (item_val,))?.as_raw())
        }
        TAG_BIGNUM | TAG_NEG_BIGNUM => decode_bignum_raw(ruby, data, pos, tag),
        TAG_BIGDEC => decode_bigdec_raw(ruby, data, pos),
        _ => {
            let inner = decode_value(ruby, data, pos)?;
            let inner_val = unsafe { Value::from_raw(inner) };
            let tagged_class = unsafe { Value::from_raw(TAGGED_CLASS) };
            Ok(tagged_class
                .funcall::<_, _, Value>("new", (tag, inner_val))?
                .as_raw())
        }
    }
}

fn decode_half_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    *pos += 1; // skip initial byte
    let b = dec_take(ruby, data, pos, 2)?;
    let b16 = u16::from_be_bytes([b[0], b[1]]);
    let exp = ((b16 >> 10) & 0x1f) as i32;
    let mant = (b16 & 0x3ff) as f64;
    let val = match exp {
        0 => mant * 2.0f64.powi(-24),
        31 => {
            if mant == 0.0 { f64::INFINITY } else { f64::NAN }
        }
        _ => (1024.0 + mant) * 2.0f64.powi(exp - 25),
    };
    let val = if (b16 >> 15) == 0 { val } else { -val };
    Ok(unsafe { rb_float_new(val) })
}

fn decode_bignum_raw(
    ruby: &Ruby,
    data: &[u8],
    pos: &mut usize,
    tag: u64,
) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)? as usize;
    let bytes = dec_take(ruby, data, pos, len)?;
    let mut val: Value = ruby.into_value(0i64);
    for &b in bytes {
        val = val.funcall("<<", (8i64,))?;
        val = val.funcall("+", (b as i64,))?;
    }
    match tag {
        TAG_BIGNUM => Ok(val.as_raw()),
        TAG_NEG_BIGNUM => {
            let neg_one: Value = ruby.into_value(-1i64);
            Ok(neg_one.funcall::<_, _, Value>("-", (val,))?.as_raw())
        }
        _ => Err(Error::new(
            cbor_error(ruby),
            format!("Invalid Tag value for BigNum, expected 2 or 3, got: {}", tag),
        )),
    }
}

fn decode_bigdec_raw(ruby: &Ruby, data: &[u8], pos: &mut usize) -> Result<VALUE, Error> {
    let (_mt, ai) = dec_read_info(ruby, data, pos)?;
    let len = dec_read_count(ruby, data, pos, ai)?;
    if len != 2 {
        return Err(Error::new(
            cbor_error(ruby),
            format!("Expected array of length 2 but length is: {}", len),
        ));
    }
    let e_raw = decode_integer_raw(ruby, data, pos)?;
    let m_raw = decode_integer_raw(ruby, data, pos)?;
    let e = unsafe { Value::from_raw(e_raw) };
    let m = unsafe { Value::from_raw(m_raw) };
    let bd_method: Value = ruby.eval("method(:BigDecimal)")?;
    let bd_m: Value = bd_method.funcall("call", (m,))?;
    let bd_10: Value = bd_method.funcall("call", (10i64,))?;
    let bd_e: Value = bd_method.funcall("call", (e,))?;
    let power: Value = bd_10.funcall("**", (bd_e,))?;
    Ok(bd_m.funcall::<_, _, Value>("*", (power,))?.as_raw())
}

// ---------------------------------------------------------------------------
// Tagged helper struct (defined first — referenced by init and encoder)
// ---------------------------------------------------------------------------

#[derive(Default)]
#[magnus::wrap(class = "AwsCrt::Cbor::Tagged", free_immediately, size)]
struct AwsCrtTagged {
    tag: Cell<u64>,
    value: Cell<VALUE>,
}

impl AwsCrtTagged {
    fn rb_initialize(rb_self: &Self, tag: u64, value: Value) {
        rb_self.tag.set(tag);
        rb_self.value.set(value.as_raw());
    }

    fn rb_tag(&self) -> u64 {
        self.tag.get()
    }

    fn rb_value(&self) -> Value {
        unsafe { Value::from_raw(self.value.get()) }
    }
}

// ---------------------------------------------------------------------------
// Encoder struct wrapper — delegates to encode_value free function
// ---------------------------------------------------------------------------

#[derive(Default)]
#[magnus::wrap(class = "AwsCrt::Cbor::Encoder", free_immediately, size)]
struct Encoder {
    buf: RefCell<Vec<u8>>,
}

impl Encoder {
    fn rb_initialize(rb_self: &Self) {
        // Pre-allocate buffer; Default gives us an empty Vec, reserve here
        rb_self.buf.borrow_mut().reserve(256);
    }

    fn rb_add(ruby: &Ruby, rb_self: typed_data::Obj<Self>, value: Value) -> Result<Value, Error> {
        {
            let mut buf = rb_self.buf.borrow_mut();
            encode_value(ruby, &mut buf, value.as_raw())?;
        }
        // Return self for chaining
        Ok(rb_self.as_value())
    }

    fn rb_bytes(rb_self: &Self) -> Result<Value, Error> {
        let buf = rb_self.buf.borrow();
        Ok(unsafe { Value::from_raw(new_encoded_string(&buf, BINARY_ENCINDEX)) })
    }
}

// ---------------------------------------------------------------------------
// Decoder struct wrapper — delegates to decode_value free function
// ---------------------------------------------------------------------------

#[derive(Default)]
#[magnus::wrap(class = "AwsCrt::Cbor::Decoder", free_immediately, size)]
struct Decoder {
    data: RefCell<Vec<u8>>,
    pos: Cell<usize>,
}

impl Decoder {
    fn rb_initialize(rb_self: &Self, bytes: RString) {
        let data = unsafe { bytes.as_slice().to_vec() };
        *rb_self.data.borrow_mut() = data;
        rb_self.pos.set(0);
    }

    fn rb_decode(ruby: &Ruby, rb_self: &Self) -> Result<Value, Error> {
        let data = rb_self.data.borrow();
        let mut pos = rb_self.pos.get();
        let result = decode_value(ruby, &data, &mut pos)?;
        rb_self.pos.set(pos);

        if pos < data.len() {
            return Err(Error::new(
                extra_bytes_error(ruby),
                format!(
                    "Extra bytes: {} bytes remaining after decode",
                    data.len() - pos
                ),
            ));
        }

        Ok(unsafe { Value::from_raw(result) })
    }
}

// ---------------------------------------------------------------------------
// Module-level encode/decode functions (JSON.dump / JSON.parse style)
// ---------------------------------------------------------------------------

fn rb_encode(ruby: &Ruby, value: Value) -> Result<Value, Error> {
    let mut buf = Vec::with_capacity(256);
    encode_value(ruby, &mut buf, value.as_raw())?;
    Ok(unsafe { Value::from_raw(new_encoded_string(&buf, BINARY_ENCINDEX)) })
}

fn rb_decode(ruby: &Ruby, bytes: Value) -> Result<Value, Error> {
    let rstr = RString::from_value(bytes).ok_or_else(|| {
        Error::new(
            exception::type_error(),
            "expected a String argument for decode",
        )
    })?;
    let (ptr, len) = unsafe { rstring_ptr_len(rstr.as_raw()) };
    let data = unsafe { std::slice::from_raw_parts(ptr, len) };
    let mut pos = 0usize;
    let result = decode_value(ruby, data, &mut pos)?;

    if pos < len {
        return Err(Error::new(
            extra_bytes_error(ruby),
            format!(
                "Extra bytes: {} bytes remaining after decode",
                len - pos
            ),
        ));
    }

    Ok(unsafe { Value::from_raw(result) })
}

// ---------------------------------------------------------------------------
// Init — register classes and module functions
// ---------------------------------------------------------------------------

pub fn init(ruby: &Ruby, module: &magnus::RModule) -> Result<(), Error> {
    let cbor = module.define_module("Cbor")?;

    // Error classes — use eval to get StandardError as RClass
    let std_error: magnus::RClass = ruby.eval("StandardError")?;
    let error_class = cbor.define_class("Error", std_error)?;
    cbor.define_class("OutOfBytesError", error_class)?;
    cbor.define_class("ExtraBytesError", error_class)?;
    cbor.define_class("UnknownTypeError", error_class)?;
    cbor.define_class("UnexpectedAdditionalInformationError", error_class)?;
    cbor.define_class("UnexpectedBreakCodeError", error_class)?;

    // Tagged struct
    let tagged = cbor.define_class("Tagged", ruby.class_object())?;
    tagged.define_alloc_func::<AwsCrtTagged>();
    tagged.define_method("initialize", method!(AwsCrtTagged::rb_initialize, 2))?;
    tagged.define_method("tag", method!(AwsCrtTagged::rb_tag, 0))?;
    tagged.define_method("value", method!(AwsCrtTagged::rb_value, 0))?;

    // Cache class references
    unsafe {
        TAGGED_CLASS = tagged.as_raw();
        cache_classes(ruby);
    }

    // Encoder class
    let encoder_class = cbor.define_class("Encoder", ruby.class_object())?;
    encoder_class.define_alloc_func::<Encoder>();
    encoder_class.define_method("initialize", method!(Encoder::rb_initialize, 0))?;
    encoder_class.define_method("add", method!(Encoder::rb_add, 1))?;
    encoder_class.define_method("bytes", method!(Encoder::rb_bytes, 0))?;

    // Decoder class
    let decoder_class = cbor.define_class("Decoder", ruby.class_object())?;
    decoder_class.define_alloc_func::<Decoder>();
    decoder_class.define_method("initialize", method!(Decoder::rb_initialize, 1))?;
    decoder_class.define_method("decode", method!(Decoder::rb_decode, 0))?;

    // Module-level encode/decode (fast path — no object allocation)
    cbor.define_module_function("encode", function!(rb_encode, 1))?;
    cbor.define_module_function("decode", function!(rb_decode, 1))?;

    Ok(())
}
