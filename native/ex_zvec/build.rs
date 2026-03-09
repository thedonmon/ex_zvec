fn main() {
    // Pure Rust — no C++ dependencies, no ZVEC_DIR needed.
    // Rustler and zvec-rs handle everything through Cargo.
    println!("cargo:rerun-if-changed=src/lib.rs");
}
