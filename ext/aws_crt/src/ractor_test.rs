//! Minimal Ractor-shareable test struct.
//!
//! `RactorTest` is a trivially simple Rust struct exposed to Ruby as
//! `AwsCrt::RactorTest`. It exists solely to demonstrate and verify
//! the `frozen_shareable` TypedData flag in isolation, without the
//! complexity of the full HTTP or S3 clients.

use std::sync::Mutex;

use magnus::prelude::*;
use magnus::typed_data::{self, DataType, DataTypeFunctions, TypedData};
use magnus::{data_type_builder, method, Error, RClass, Ruby};
use magnus::value::Lazy;

/// A minimal Ractor-shareable struct.
///
/// Holds an immutable name and a Mutex-protected counter to prove
/// that interior mutability behind Rust synchronization primitives
/// works correctly across Ractors.
pub struct RactorTest {
    name: String,
    counter: Mutex<u64>,
}

// SAFETY: All mutable state is behind Mutex. No Ruby VALUEs stored.
unsafe impl Send for RactorTest {}
unsafe impl Sync for RactorTest {}

impl DataTypeFunctions for RactorTest {}

unsafe impl TypedData for RactorTest {
    fn class(ruby: &Ruby) -> RClass {
        static CLASS: Lazy<RClass> = Lazy::new(|ruby| {
            ruby.class_object()
                .const_get::<_, magnus::RModule>("AwsCrt")
                .unwrap()
                .const_get("RactorTest")
                .unwrap()
        });
        ruby.get_inner(&CLASS)
    }

    fn data_type() -> &'static DataType {
        static DATA_TYPE: DataType = data_type_builder!(RactorTest, "AwsCrt::RactorTest")
            .free_immediately()
            .frozen_shareable()
            .build();
        &DATA_TYPE
    }
}

impl RactorTest {
    /// Ruby: `RactorTest.new(name)`
    fn rb_new(name: String) -> typed_data::Obj<Self> {
        typed_data::Obj::wrap(RactorTest {
            name,
            counter: Mutex::new(0),
        })
    }

    /// Ruby: `obj.name` — returns the immutable name.
    fn rb_name(&self) -> String {
        self.name.clone()
    }

    /// Ruby: `obj.counter` — returns the current counter value.
    fn rb_counter(&self) -> u64 {
        *self.counter.lock().unwrap()
    }

    /// Ruby: `obj.increment` — atomically increments and returns new value.
    fn rb_increment(&self) -> u64 {
        let mut c = self.counter.lock().unwrap();
        *c += 1;
        *c
    }
}

/// Register `AwsCrt::RactorTest` with Ruby.
pub fn define_ractor_test(
    ruby: &Ruby,
    module: &magnus::RModule,
) -> Result<(), Error> {
    let class = module.define_class("RactorTest", ruby.class_object())?;
    class.undef_default_alloc_func();
    class.define_singleton_method("new", magnus::function!(RactorTest::rb_new, 1))?;
    class.define_method("name", method!(RactorTest::rb_name, 0))?;
    class.define_method("counter", method!(RactorTest::rb_counter, 0))?;
    class.define_method("increment", method!(RactorTest::rb_increment, 0))?;

    Ok(())
}
