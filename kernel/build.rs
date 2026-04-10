fn main() {
    // Tell cargo to recompile when CPU_SCHED changes.
    println!("cargo:rerun-if-env-changed=CPU_SCHED");
}
