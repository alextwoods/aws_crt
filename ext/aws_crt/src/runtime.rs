//! Process-global CRT resource lifecycle management.
//!
//! Provides a singleton `CrtRuntime` that lazily initializes the shared CRT
//! resources (Event Loop Group, Host Resolver, Client Bootstrap) on first use.
//! Resources are intentionally not released at process exit — the OS reclaims
//! them, and explicit teardown would block on pending connection manager
//! references that Ruby's GC may not have collected yet.
//!
//! Thread safety is guaranteed by `OnceLock` — multiple Ruby threads calling
//! `CrtRuntime::get()` concurrently will all receive the same instance, and
//! the underlying CRT resources are initialized exactly once.

use std::sync::OnceLock;

use crate::error::CrtError;

// ---------------------------------------------------------------------------
// Opaque CRT types (pointers only — we never inspect the structs)
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct AwsAllocator {
    _opaque: [u8; 0],
}

#[repr(C)]
pub struct AwsEventLoopGroup {
    _opaque: [u8; 0],
}

#[repr(C)]
pub struct AwsHostResolver {
    _opaque: [u8; 0],
}

#[repr(C)]
pub struct AwsClientBootstrap {
    _opaque: [u8; 0],
}

// ---------------------------------------------------------------------------
// FFI option structs — must match the C layout exactly
// ---------------------------------------------------------------------------

/// Mirrors `struct aws_event_loop_group_options` from aws-c-io/event_loop.h.
///
/// Fields after `loop_count` and `type` are optional pointers that we leave
/// null for default behaviour.
#[repr(C)]
struct AwsEventLoopGroupOptions {
    loop_count: u16,
    el_type: u32, // enum aws_event_loop_type (C int)
    shutdown_options: *const std::ffi::c_void,
    cpu_group: *const u16,
    clock_override: *const std::ffi::c_void,
}

/// Mirrors `struct aws_host_resolver_default_options` from aws-c-io/host_resolver.h.
#[repr(C)]
struct AwsHostResolverDefaultOptions {
    max_entries: usize,
    el_group: *mut AwsEventLoopGroup,
    shutdown_options: *const std::ffi::c_void,
    system_clock_override_fn: *const std::ffi::c_void,
}

/// Mirrors `struct aws_client_bootstrap_options` from aws-c-io/channel_bootstrap.h.
#[repr(C)]
struct AwsClientBootstrapOptions {
    event_loop_group: *mut AwsEventLoopGroup,
    host_resolver: *mut AwsHostResolver,
    host_resolution_config: *const std::ffi::c_void,
    on_shutdown_complete: *const std::ffi::c_void,
    user_data: *const std::ffi::c_void,
}

// ---------------------------------------------------------------------------
// FFI declarations
// ---------------------------------------------------------------------------

extern "C" {
    fn aws_default_allocator() -> *mut AwsAllocator;
    fn aws_http_library_init(allocator: *mut AwsAllocator);

    fn aws_event_loop_group_new(
        allocator: *mut AwsAllocator,
        options: *const AwsEventLoopGroupOptions,
    ) -> *mut AwsEventLoopGroup;
    fn aws_event_loop_group_release(el_group: *mut AwsEventLoopGroup);

    fn aws_host_resolver_new_default(
        allocator: *mut AwsAllocator,
        options: *const AwsHostResolverDefaultOptions,
    ) -> *mut AwsHostResolver;
    fn aws_host_resolver_release(resolver: *mut AwsHostResolver);

    fn aws_client_bootstrap_new(
        allocator: *mut AwsAllocator,
        options: *const AwsClientBootstrapOptions,
    ) -> *mut AwsClientBootstrap;
    // Used only in init() error paths; kept for completeness.
    #[allow(dead_code)]
    fn aws_client_bootstrap_release(bootstrap: *mut AwsClientBootstrap);

    // Ruby C API — register a function to run at process exit
    fn rb_set_end_proc(
        func: unsafe extern "C" fn(data: *mut std::ffi::c_void),
        data: *mut std::ffi::c_void,
    );
}

// ---------------------------------------------------------------------------
// CrtRuntime — singleton holding shared CRT resources
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<CrtRuntime> = OnceLock::new();

/// Process-global CRT resources shared by all HTTP connection managers.
///
/// Initialized lazily on first access via `CrtRuntime::get()`. The event loop
/// group thread count matches the number of available CPU cores.
pub struct CrtRuntime {
    allocator: *mut AwsAllocator,
    // Stored to keep the CRT resources alive for the process lifetime.
    // Not read directly — the CRT holds internal references via the bootstrap.
    #[allow(dead_code)]
    event_loop_group: *mut AwsEventLoopGroup,
    #[allow(dead_code)]
    host_resolver: *mut AwsHostResolver,
    client_bootstrap: *mut AwsClientBootstrap,
}

// The CRT resources are internally thread-safe (event loop group, host resolver,
// and client bootstrap are all designed for concurrent access). The raw pointers
// are stable for the process lifetime, so Send + Sync is sound.
unsafe impl Send for CrtRuntime {}
unsafe impl Sync for CrtRuntime {}

impl CrtRuntime {
    /// Returns the singleton CRT runtime, initializing it on first call.
    ///
    /// This is safe to call from any Ruby thread — `OnceLock` ensures the
    /// initialization runs exactly once.
    ///
    /// # Panics
    ///
    /// Panics if CRT resource initialization fails (e.g. event loop group
    /// creation returns null). This is unrecoverable — if the CRT cannot
    /// create an event loop, no HTTP operations are possible.
    pub fn get() -> &'static CrtRuntime {
        RUNTIME.get_or_init(|| Self::init().expect("Failed to initialize CRT runtime"))
    }

    /// Returns the shared allocator pointer.
    pub fn allocator(&self) -> *mut AwsAllocator {
        self.allocator
    }

    /// Returns the shared client bootstrap pointer.
    pub fn client_bootstrap(&self) -> *mut AwsClientBootstrap {
        self.client_bootstrap
    }

    /// Initialize all CRT resources. Called exactly once by `OnceLock`.
    fn init() -> Result<CrtRuntime, CrtError> {
        let allocator = unsafe { aws_default_allocator() };

        // aws_http_library_init transitively initializes:
        //   aws-c-common → aws-c-cal → aws-c-io → aws-c-compression → aws-c-http
        unsafe { aws_http_library_init(allocator) };

        // Event loop group — one thread per available CPU core
        let num_threads = std::thread::available_parallelism()
            .map(|n| n.get() as u16)
            .unwrap_or(1);

        let elg_options = AwsEventLoopGroupOptions {
            loop_count: num_threads,
            el_type: 0, // AWS_EVENT_LOOP_PLATFORM_DEFAULT
            shutdown_options: std::ptr::null(),
            cpu_group: std::ptr::null(),
            clock_override: std::ptr::null(),
        };

        let event_loop_group =
            unsafe { aws_event_loop_group_new(allocator, &elg_options) };
        if event_loop_group.is_null() {
            return Err(CrtError::last_error());
        }

        // Host resolver — 64 cached entries is a reasonable default
        let resolver_options = AwsHostResolverDefaultOptions {
            max_entries: 64,
            el_group: event_loop_group,
            shutdown_options: std::ptr::null(),
            system_clock_override_fn: std::ptr::null(),
        };

        let host_resolver =
            unsafe { aws_host_resolver_new_default(allocator, &resolver_options) };
        if host_resolver.is_null() {
            unsafe { aws_event_loop_group_release(event_loop_group) };
            return Err(CrtError::last_error());
        }

        // Client bootstrap — binds the event loop group and host resolver
        let bootstrap_options = AwsClientBootstrapOptions {
            event_loop_group,
            host_resolver,
            host_resolution_config: std::ptr::null(),
            on_shutdown_complete: std::ptr::null(),
            user_data: std::ptr::null(),
        };

        let client_bootstrap =
            unsafe { aws_client_bootstrap_new(allocator, &bootstrap_options) };
        if client_bootstrap.is_null() {
            unsafe {
                aws_host_resolver_release(host_resolver);
                aws_event_loop_group_release(event_loop_group);
            }
            return Err(CrtError::last_error());
        }

        // Register cleanup at Ruby process exit
        unsafe {
            rb_set_end_proc(runtime_cleanup, std::ptr::null_mut());
        }

        Ok(CrtRuntime {
            allocator,
            event_loop_group,
            host_resolver,
            client_bootstrap,
        })
    }
}

/// Called by Ruby at process exit via `rb_set_end_proc`.
///
/// Intentionally a no-op. The CRT's reference-counted shutdown model means
/// `aws_event_loop_group_release` blocks until every connection manager that
/// holds a reference has been released first. Because Ruby's GC may not have
/// collected all `ConnectionPool` (and thus `ConnectionManager`) objects
/// before this `at_exit` hook runs, the event loop group release can block
/// for the CRT's internal shutdown timeout (~30 seconds).
///
/// Skipping explicit cleanup is safe and intentional:
///   - The OS reclaims all process memory and file descriptors on exit.
///   - This is a common pattern in native extensions — cleanup at exit is
///     often more harmful than helpful (see e.g. Python's approach to
///     C extension module cleanup).
///   - The CRT event loop threads are daemon-like and will be terminated
///     by the OS when the process exits.
unsafe extern "C" fn runtime_cleanup(_data: *mut std::ffi::c_void) {
    // No-op: let the OS reclaim resources on process exit.
    // See doc comment above for rationale.
}
