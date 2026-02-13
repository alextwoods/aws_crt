use std::env;
use std::path::PathBuf;

fn main() {
    // The CRT libraries must be pre-built before compiling this extension.
    // Use `rake crt:compile` to build them into crt/install/.
    let root_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../..");
    let root_dir = root_dir.canonicalize()
        .expect("Failed to resolve project root directory");

    let crt_install_dir = match env::var("CRT_INSTALL_DIR") {
        Ok(dir) => PathBuf::from(dir),
        Err(_) => root_dir.join("crt").join("install"),
    };

    let include_dir = crt_install_dir.join("include");
    let lib_dir = ["lib", "lib64"]
        .iter()
        .map(|d| crt_install_dir.join(d))
        .find(|d| d.exists())
        .unwrap_or_else(|| {
            panic!(
                "Pre-built CRT libraries not found at {}.\n\
                 Please build the CRT libraries first: rake crt:compile",
                crt_install_dir.display()
            )
        });

    if !include_dir.exists() {
        panic!(
            "CRT include directory not found at {}.\n\
             Please build the CRT libraries first: rake crt:compile",
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
}
