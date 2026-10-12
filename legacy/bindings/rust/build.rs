use std::env;
use std::path::PathBuf;

fn main() {
    // Locates the root of the legacy project based on the Cargo manifest
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let root_path = PathBuf::from(manifest_dir)
        .parent() // get out of Rust/
        .unwrap()
        .parent() // get out of bindings/
        .unwrap()
        .to_path_buf();

    let lib_dir = if let Ok(custom_path) = env::var("LEGACY_LIB_DIR") {
        PathBuf::from(custom_path)
    } else {
        root_path.join("lib")
    };

    // Tells the linker where to look for the C++ artifact.
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=_cpp_api");

    // Ensures that if the header or the library changes, the build is recompiled.
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=build.rs");
}
