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
    println!("cargo:rustc-link-lib=static=aws-checksums");
    println!("cargo:rustc-link-lib=static=aws-c-common");

    // Platform-specific system libraries
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match target_os.as_str() {
        "macos" => {
            println!("cargo:rustc-link-lib=framework=CoreFoundation");
            println!("cargo:rustc-link-lib=framework=Security");
        }
        "linux" => {
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
