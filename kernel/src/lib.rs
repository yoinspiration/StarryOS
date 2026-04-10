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
// CPU 0: EEVDF (fair scheduling with deadline guarantees)
// CPU 1: FIFO  (real-time tasks, no preemption)
// Other CPUs: EEVDF (default)
#[cfg(feature = "sched-per-cpu")]
struct SchedSetup;

#[cfg(feature = "sched-per-cpu")]
#[crate_interface::impl_interface]
impl axtask::PerCpuSchedSetup for SchedSetup {
    fn setup_per_cpu_schedulers() {
        axtask::set_cpu_scheduler_kind(0, axsched::SchedulerKind::Eevdf);
        axtask::set_cpu_scheduler_kind(1, axsched::SchedulerKind::Fifo);
    }
}

mod config;
mod file;
mod mm;
mod pseudofs;
mod syscall;
mod task;
mod time;
