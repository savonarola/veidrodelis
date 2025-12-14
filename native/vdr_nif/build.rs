fn main() {
    cc::Build::new()
        .file("c_src/lzf_c.c")
        .file("c_src/lzf_d.c")
        .include("c_src")
        .opt_level(3)
        .flag_if_supported("-std=c99")
        .flag_if_supported("-finline-functions")
        .flag_if_supported("-Wall")
        .compile("lzf");

    println!("cargo:rerun-if-changed=c_src/lzf_c.c");
    println!("cargo:rerun-if-changed=c_src/lzf_d.c");
    println!("cargo:rerun-if-changed=c_src/lzf.h");
    println!("cargo:rerun-if-changed=c_src/lzfP.h");
}
