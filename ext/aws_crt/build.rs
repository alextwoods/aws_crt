use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Locate cmake on the system, preferring `cmake3` (common on older distros).
fn find_cmake() -> String {
    for name in &["cmake3", "cmake"] {
        if Command::new(name)
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
        {
            return name.to_string();
        }
    }
    panic!(
        "cmake not found.\n\
         Please install cmake (https://cmake.org/) to build the CRT libraries."
    );
}

/// Return the number of logical CPUs (for parallel builds).
fn num_cpus() -> String {
    std::thread::available_parallelism()
        .map(|n| n.get().to_string())
        .unwrap_or_else(|_| "1".to_string())
}

/// Build the CRT C libraries from source using cmake.
///
/// This mirrors the logic in `ext/crt_compile.rb` / `rake crt:compile`
/// so that the gem can be installed from a git source without needing
/// Rake.
fn compile_crt(crt_dir: &Path, install_dir: &Path) {
    let cmake = find_cmake();
    let build_dir = crt_dir.join("build");
    std::fs::create_dir_all(&build_dir).expect("Failed to create CRT build directory");

    let build_type = "RelWithDebInfo";

    // Configure
    let status = Command::new(&cmake)
        .args([
            "-S",
            crt_dir.to_str().unwrap(),
            "-B",
            build_dir.to_str().unwrap(),
            &format!("-DCMAKE_INSTALL_PREFIX={}", install_dir.display()),
            &format!("-DCMAKE_BUILD_TYPE={}", build_type),
            "-DBUILD_TESTING=OFF",
            "-DBUILD_SHARED_LIBS=OFF",
        ])
        .status()
        .expect("Failed to run cmake configure");
    if !status.success() {
        panic!("cmake configure failed (exit code {:?})", status.code());
    }

    // Build + install
    let status = Command::new(&cmake)
        .args([
            "--build",
            build_dir.to_str().unwrap(),
            "--target",
            "install",
            "--config",
            build_type,
            "--parallel",
            &num_cpus(),
        ])
        .status()
        .expect("Failed to run cmake build");
    if !status.success() {
        panic!("cmake build failed (exit code {:?})", status.code());
    }

    println!("cargo:warning=CRT libraries compiled and installed to {}", install_dir.display());
}

/// Check whether the CRT install directory already contains the
/// expected lib directory (lib/ or lib64/).
fn find_lib_dir(crt_install_dir: &Path) -> Option<PathBuf> {
    ["lib", "lib64"]
        .iter()
        .map(|d| crt_install_dir.join(d))
        .find(|d| d.exists())
}

fn main() {
    let root_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let root_dir = root_dir
        .canonicalize()
        .expect("Failed to resolve project root directory");

    let crt_install_dir = match env::var("CRT_INSTALL_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => root_dir.join("crt").join("install"),
    };

    // If the CRT libraries haven't been pre-built, build them now.
    // This makes `gem install` from a git source work without a
    // separate `rake crt:compile` step.
    if find_lib_dir(&crt_install_dir).is_none() || !crt_install_dir.join("include").exists() {
        let crt_dir = root_dir.join("crt");
        if crt_dir.join("CMakeLists.txt").exists() {
            println!(
                "cargo:warning=CRT libraries not found at {}; building from source...",
                crt_install_dir.display()
            );
            compile_crt(&crt_dir, &crt_install_dir);
        } else {
            panic!(
                "Pre-built CRT libraries not found at {} and CRT source tree \
                 not available at {}.\n\
                 Please build the CRT libraries first: rake crt:compile",
                crt_install_dir.display(),
                crt_dir.display()
            );
        }
    }

    let include_dir = crt_install_dir.join("include");
    let lib_dir = find_lib_dir(&crt_install_dir).unwrap_or_else(|| {
        panic!(
            "CRT lib directory not found at {} even after build.\n\
             Please check the cmake output above for errors.",
            crt_install_dir.display()
        )
    });

    if !include_dir.exists() {
        panic!(
            "CRT include directory not found at {} even after build.\n\
             Please check the cmake output above for errors.",
            include_dir.display()
        );
    }

    // Tell cargo where to find the static libraries
    println!("cargo:rustc-link-search=native={}", lib_dir.display());

    // Link the CRT static libraries (order matters: dependents first)
    // S3 stack
    let required_libs = [
        "aws-c-s3",
        "aws-c-auth",
        "aws-c-sdkutils",
        // HTTP stack
        "aws-c-http",
        "aws-c-compression",
        "aws-c-io",
        "aws-c-cal",
        // Existing
        "aws-checksums",
        "aws-c-common",
    ];

    for lib in &required_libs {
        let lib_file = lib_dir.join(format!("lib{}.a", lib));
        if !lib_file.exists() {
            panic!(
                "Required CRT library '{}' not found at {}.\n\
                 Please rebuild the CRT libraries: rake crt:compile",
                lib,
                lib_file.display()
            );
        }
        println!("cargo:rustc-link-lib=static={}", lib);
    }

    // Platform-specific system libraries
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match target_os.as_str() {
        "macos" => {
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            println!("cargo:rustc-link-lib=framework=Security");
            println!("cargo:rustc-link-lib=framework=Network");
        }
        "linux" => {
            // s2n-tls and libcrypto (from AWS-LC) are prebuilt into
            // the same install tree by the CMake build.
            let s2n_lib = lib_dir.join("libs2n.a");
            if !s2n_lib.exists() {
                panic!(
                    "Required CRT library 's2n' not found at {}.\n\
                     Please rebuild the CRT libraries: rake crt:compile",
                    s2n_lib.display()
                );
            }
            let crypto_lib = lib_dir.join("libcrypto.a");
            if !crypto_lib.exists() {
                panic!(
                    "Required CRT library 'crypto' (AWS-LC) not found at {}.\n\
                     Please rebuild the CRT libraries: rake crt:compile",
                    crypto_lib.display()
                );
            }
            println!("cargo:rustc-link-lib=static=s2n");
            println!("cargo:rustc-link-lib=static=crypto");
            println!("cargo:rustc-link-lib=dylib=pthread");
            println!("cargo:rustc-link-lib=dylib=dl");
        }
        _ => {}
    }

    // Re-run build script if the CRT install changes
    println!("cargo:rerun-if-env-changed=CRT_INSTALL_DIR");
    println!("cargo:rerun-if-changed={}", lib_dir.display());
    println!("cargo:rerun-if-changed={}", include_dir.display());

    // Compile the C helper for signing config initialization.
    // This is needed because aws_signing_config_aws contains
    // platform-dependent types (struct tm inside aws_date_time)
    // that cannot be reliably replicated in Rust.
    let c_src = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("src")
        .join("signing_config_init.c");
    if c_src.exists() {
        cc::Build::new()
            .file(&c_src)
            .include(&include_dir)
            .opt_level(2)
            .compile("signing_config_init");
        println!("cargo:rerun-if-changed={}", c_src.display());
    }
}
