use std::env;
use std::path::PathBuf;

fn main() {
    // ZVEC_DIR: path to zvec source root (containing src/include/ headers)
    // ZVEC_BUILD_DIR: path to zvec cmake build directory (containing compiled libs)
    let zvec_dir = env::var("ZVEC_DIR")
        .expect("Set ZVEC_DIR to the zvec source root (e.g. /path/to/zvec)");
    let zvec_build_dir = env::var("ZVEC_BUILD_DIR")
        .unwrap_or_else(|_| format!("{}/build", zvec_dir));

    let zvec_path = PathBuf::from(&zvec_dir);
    let build_path = PathBuf::from(&zvec_build_dir);

    // Add all possible lib search paths from the cmake build tree
    add_lib_search_paths(&build_path);

    // zvec core static libraries
    let zvec_lib = build_path.join("lib");
    println!("cargo:rustc-link-search=native={}", zvec_lib.display());

    // zvec_core is a combined archive containing all core_* objects
    // (metric factories, converter factories, index factories, etc.)
    // Must force-load it because it uses static self-registration constructors
    // that the linker would otherwise strip as "unused".
    let zvec_core_path = zvec_lib.join("libzvec_core.a");
    if cfg!(target_os = "macos") {
        println!(
            "cargo:rustc-link-arg=-Wl,-force_load,{}",
            zvec_core_path.display()
        );
    } else {
        println!("cargo:rustc-link-arg=-Wl,--whole-archive");
        println!("cargo:rustc-link-lib=static=zvec_core");
        println!("cargo:rustc-link-arg=-Wl,--no-whole-archive");
    }

    // Remaining zvec libs
    println!("cargo:rustc-link-lib=static=zvec_db");
    println!("cargo:rustc-link-lib=static=zvec_sqlengine");
    println!("cargo:rustc-link-lib=static=zvec_index");
    println!("cargo:rustc-link-lib=static=zvec_common");
    println!("cargo:rustc-link-lib=static=zvec_ailego");
    println!("cargo:rustc-link-lib=static=zvec_proto");
    println!("cargo:rustc-link-lib=static=core_utility");

    // Third-party static libs built by zvec's CMake
    let ext_lib = build_path.join("external/usr/local/lib");
    println!(
        "cargo:rustc-link-search=native={}",
        ext_lib.display()
    );
    println!("cargo:rustc-link-lib=static=rocksdb");
    println!("cargo:rustc-link-lib=static=glog");
    println!("cargo:rustc-link-lib=static=gflags_nothreads");
    println!("cargo:rustc-link-lib=static=lz4");
    println!("cargo:rustc-link-lib=static=protobuf");
    println!("cargo:rustc-link-lib=static=roaring");
    println!("cargo:rustc-link-lib=static=antlr4-runtime");

    // Arrow and related libs
    println!("cargo:rustc-link-lib=static=arrow");
    println!("cargo:rustc-link-lib=static=arrow_dataset");
    println!("cargo:rustc-link-lib=static=parquet");
    println!("cargo:rustc-link-lib=static=arrow_bundled_dependencies");
    println!("cargo:rustc-link-lib=static=arrow_acero");
    println!("cargo:rustc-link-lib=static=arrow_compute");

    // System libraries
    if cfg!(target_os = "macos") {
        println!("cargo:rustc-link-lib=dylib=c++");
    } else {
        println!("cargo:rustc-link-lib=dylib=stdc++");
    }
    println!("cargo:rustc-link-lib=dylib=z");
    println!("cargo:rustc-link-lib=dylib=bz2");

    // Include paths for cxx bridge compilation
    let zvec_include = zvec_path.join("src/include");
    let zvec_src = zvec_path.join("src");
    let ext_include = build_path.join("external/usr/local/include");

    // Build cxx bridge + our C++ wrapper
    cxx_build::bridge("src/lib.rs")
        .file("cpp/zvec_wrapper.cpp")
        .include(&zvec_include)
        .include(&zvec_src)
        .include(&ext_include)
        .include("cpp")
        .flag_if_supported("-std=c++17")
        .flag_if_supported("-O2")
        .compile("ex_zvec_bridge");

    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=cpp/zvec_wrapper.h");
    println!("cargo:rerun-if-changed=cpp/zvec_wrapper.cpp");
}

/// Recursively find and add lib search paths from the cmake build tree.
fn add_lib_search_paths(build_path: &PathBuf) {
    let search_dirs = vec![
        build_path.join("src/db"),
        build_path.join("src/core/knn/hnsw"),
        build_path.join("src/core/knn/flat"),
        build_path.join("src/core/knn/ivf"),
        build_path.join("src/core/knn/flat_sparse"),
        build_path.join("src/core/knn/hnsw_sparse"),
        build_path.join("src/core/knn/cluster"),
        build_path.join("src/core/metric"),
        build_path.join("src/core/utility"),
        build_path.join("src/core/quantizer"),
        build_path.join("src/core/mix_reducer"),
        build_path.join("external/usr/local/lib"),
        build_path.join("thirdparty/rocksdb"),
        build_path.join("thirdparty/glog"),
        build_path.join("thirdparty/gflags"),
        build_path.join("thirdparty/lz4"),
        build_path.join("thirdparty/protobuf"),
        build_path.join("thirdparty/yaml-cpp"),
        build_path.join("thirdparty/CRoaring"),
        build_path.join("thirdparty/antlr"),
        build_path.join("thirdparty/arrow"),
    ];

    for dir in search_dirs {
        if dir.exists() {
            println!("cargo:rustc-link-search=native={}", dir.display());
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    if entry.path().is_dir() {
                        println!(
                            "cargo:rustc-link-search=native={}",
                            entry.path().display()
                        );
                    }
                }
            }
        }
    }
}
