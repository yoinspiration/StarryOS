use std::env;
use std::fs;
use std::path::Path;

fn main() {
    println!("cargo:rerun-if-env-changed=CPU_SCHED");

    let cpu_sched = env::var("CPU_SCHED").unwrap_or_default();
    let out_dir = env::var("OUT_DIR").unwrap();
    let dest = Path::new(&out_dir).join("cpu_sched_config.rs");
    // Write a const that will be include!-d into lib.rs.
    let escaped = cpu_sched.replace('\\', "\\\\").replace('"', "\\\"");
    fs::write(dest, format!("const CPU_SCHED_CONFIG: &str = \"{escaped}\";\n")).unwrap();
}
