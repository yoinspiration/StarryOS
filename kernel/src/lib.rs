//! The core functionality of a monolithic kernel, including loading user
//! programs and managing processes.

#![no_std]
#![feature(likely_unlikely)]
#![feature(bstr)]
#![allow(missing_docs)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

extern crate alloc;
extern crate axruntime;

#[macro_use]
extern crate axlog;

pub mod entry;

// Configure per-CPU scheduler kinds before init_scheduler is called.
//
// Reads the `CPU_SCHED` environment variable at compile time.
// Format: "0:eevdf,1:fifo,2:rr"  (cpu_id:algorithm pairs, comma-separated)
// Unspecified CPUs default to EEVDF.
//
// Example:
//   CPU_SCHED="0:eevdf,1:fifo" make run SMP=2
#[cfg(feature = "sched-per-cpu")]
struct SchedSetup;

#[cfg(feature = "sched-per-cpu")]
#[crate_interface::impl_interface]
impl axtask::PerCpuSchedSetup for SchedSetup {
    fn setup_per_cpu_schedulers() {
        const CONFIG: &str = match option_env!("CPU_SCHED") {
            Some(s) => s,
            None => "0:eevdf",  // default: CPU 0 uses EEVDF
        };
        for entry in CONFIG.split(',') {
            let mut parts = entry.trim().splitn(2, ':');
            let cpu_id = match parts.next().and_then(|s| s.parse::<usize>().ok()) {
                Some(id) => id,
                None => continue,
            };
            let kind = match parts.next() {
                Some("fifo") => axsched::SchedulerKind::Fifo,
                Some("rr")   => axsched::SchedulerKind::Rr,
                _            => axsched::SchedulerKind::Eevdf,
            };
            axtask::set_cpu_scheduler_kind(cpu_id, kind);
        }
    }
}

mod config;
mod file;
mod mm;
mod pseudofs;
mod syscall;
mod task;
mod time;
