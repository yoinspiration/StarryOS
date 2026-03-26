use axerrno::{AxError, AxResult};
use axhal::time::TimeValue;
use axtask::{
    AxCpuMask, current,
    future::{block_on, interruptible, sleep},
};
use linux_raw_sys::general::{
    __kernel_clockid_t, CLOCK_MONOTONIC, CLOCK_REALTIME, PRIO_PGRP, PRIO_PROCESS, PRIO_USER,
    SCHED_RR, TIMER_ABSTIME, timespec,
};
use starry_vm::{VmMutPtr, VmPtr, vm_load, vm_write_slice};

use crate::{
    task::{get_process_data, get_process_group, AsThread},
    time::TimeValueLike,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SetPriorityTarget {
    CurrentProcess,
    UnsupportedProcess,
    UnsupportedScope,
    InvalidScope,
}

fn classify_setpriority_target(which: u32, who: u32, curr_pid: u32) -> SetPriorityTarget {
    match which {
        PRIO_PROCESS => {
            if who == 0 || who == curr_pid {
                SetPriorityTarget::CurrentProcess
            } else {
                SetPriorityTarget::UnsupportedProcess
            }
        }
        PRIO_PGRP | PRIO_USER => SetPriorityTarget::UnsupportedScope,
        _ => SetPriorityTarget::InvalidScope,
    }
}

pub fn sys_sched_yield() -> AxResult<isize> {
    axtask::yield_now();
    Ok(0)
}

fn sleep_impl(clock: impl Fn() -> TimeValue, dur: TimeValue) -> TimeValue {
    debug!("sleep_impl <= {dur:?}");

    let start = clock();

    // TODO: currently ignoring concrete clock type
    // We detect EINTR manually if the slept time is not enough.
    let _ = block_on(interruptible(sleep(dur)));

    clock() - start
}

/// Sleep some nanoseconds
pub fn sys_nanosleep(req: *const timespec, rem: *mut timespec) -> AxResult<isize> {
    // FIXME: AnyBitPattern
    let req = unsafe { req.vm_read_uninit()?.assume_init() }.try_into_time_value()?;
    debug!("sys_nanosleep <= req: {req:?}");

    let actual = sleep_impl(axhal::time::monotonic_time, req);

    if let Some(diff) = req.checked_sub(actual) {
        debug!("sys_nanosleep => rem: {diff:?}");
        if let Some(rem) = rem.nullable() {
            rem.vm_write(timespec::from_time_value(diff))?;
        }
        Err(AxError::Interrupted)
    } else {
        Ok(0)
    }
}

pub fn sys_clock_nanosleep(
    clock_id: __kernel_clockid_t,
    flags: u32,
    req: *const timespec,
    rem: *mut timespec,
) -> AxResult<isize> {
    let clock = match clock_id as u32 {
        CLOCK_REALTIME => axhal::time::wall_time,
        CLOCK_MONOTONIC => axhal::time::monotonic_time,
        _ => {
            warn!("Unsupported clock_id: {clock_id}");
            return Err(AxError::InvalidInput);
        }
    };

    let req = unsafe { req.vm_read_uninit()?.assume_init() }.try_into_time_value()?;
    debug!("sys_clock_nanosleep <= clock_id: {clock_id}, flags: {flags}, req: {req:?}");

    let dur = if flags & TIMER_ABSTIME != 0 {
        req.saturating_sub(clock())
    } else {
        req
    };

    let actual = sleep_impl(clock, dur);

    if let Some(diff) = dur.checked_sub(actual) {
        debug!("sys_clock_nanosleep => rem: {diff:?}");
        if let Some(rem) = rem.nullable() {
            rem.vm_write(timespec::from_time_value(diff))?;
        }
        Err(AxError::Interrupted)
    } else {
        Ok(0)
    }
}

pub fn sys_sched_getaffinity(pid: i32, cpusetsize: usize, user_mask: *mut u8) -> AxResult<isize> {
    if cpusetsize * 8 < axhal::cpu_num() {
        return Err(AxError::InvalidInput);
    }

    // TODO: support other threads
    if pid != 0 {
        return Err(AxError::OperationNotPermitted);
    }

    let mask = current().cpumask();
    let mask_bytes = mask.as_bytes();

    vm_write_slice(user_mask, mask_bytes)?;

    Ok(mask_bytes.len() as _)
}

pub fn sys_sched_setaffinity(
    _pid: i32,
    cpusetsize: usize,
    user_mask: *const u8,
) -> AxResult<isize> {
    let size = cpusetsize.min(axhal::cpu_num().div_ceil(8));
    let user_mask = vm_load(user_mask, size)?;
    let mut cpu_mask = AxCpuMask::new();

    for i in 0..(size * 8).min(axhal::cpu_num()) {
        if user_mask[i / 8] & (1 << (i % 8)) != 0 {
            cpu_mask.set(i, true);
        }
    }

    // TODO: support other threads
    axtask::set_current_affinity(cpu_mask);

    Ok(0)
}

pub fn sys_sched_getscheduler(_pid: i32) -> AxResult<isize> {
    Ok(SCHED_RR as _)
}

pub fn sys_sched_setscheduler(_pid: i32, _policy: i32, _param: *const ()) -> AxResult<isize> {
    Ok(0)
}

pub fn sys_sched_getparam(_pid: i32, _param: *mut ()) -> AxResult<isize> {
    Ok(0)
}

pub fn sys_getpriority(which: u32, who: u32) -> AxResult<isize> {
    debug!("sys_getpriority <= which: {which}, who: {who}");

    match which {
        PRIO_PROCESS => {
            // Keep behavior consistent with current setpriority boundary:
            // - target scope is accepted as PRIO_PROCESS
            // - if `who != 0`, we only validate target existence now
            // - return value is still a fixed placeholder until per-task nice
            //   state is fully wired through scheduler/task metadata.
            // TODO: return effective nice of target process.
            if who != 0 {
                let _proc = get_process_data(who)?;
            }
            Ok(20)
        }
        PRIO_PGRP => {
            // TODO: align semantics with sys_setpriority by rejecting unsupported
            // scopes, or implement real process-group priority querying.
            if who != 0 {
                let _pg = get_process_group(who)?;
            }
            Ok(20)
        }
        PRIO_USER => {
            if who == 0 {
                Ok(20)
            } else {
                Err(AxError::NoSuchProcess)
            }
        }
        _ => Err(AxError::InvalidInput),
    }
}

pub fn sys_setpriority(which: u32, who: u32, prio: i32) -> AxResult<isize> {
    debug!("sys_setpriority <= which: {which}, who: {who}, prio: {prio}");

    // Current semantic boundary (intentionally minimal):
    // - only supports PRIO_PROCESS
    // - only allows changing current process (`who == 0` or current pid)
    // Other scopes / targets return OperationNotPermitted for now.
    if !(-20..=19).contains(&prio) {
        return Err(AxError::InvalidInput);
    }

    let curr_pid = current().as_thread().proc_data.proc.pid() as u32;
    match classify_setpriority_target(which, who, curr_pid) {
        SetPriorityTarget::CurrentProcess => {
            // Minimal support: allow changing the current process only.
            // On Linux, `nice` may pass `who = 0` or `who = getpid()`.
            if axtask::set_priority(prio as isize) {
                Ok(0)
            } else {
                Err(AxError::InvalidInput)
            }
        }
        SetPriorityTarget::UnsupportedProcess => {
            // We don't support changing other processes yet.
            let _proc = get_process_data(who)?;
            Err(AxError::OperationNotPermitted)
        }
        SetPriorityTarget::UnsupportedScope => Err(AxError::OperationNotPermitted),
        SetPriorityTarget::InvalidScope => Err(AxError::InvalidInput),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_accepts_current_process_by_zero_or_pid() {
        assert_eq!(
            classify_setpriority_target(PRIO_PROCESS, 0, 123),
            SetPriorityTarget::CurrentProcess
        );
        assert_eq!(
            classify_setpriority_target(PRIO_PROCESS, 123, 123),
            SetPriorityTarget::CurrentProcess
        );
    }

    #[test]
    fn classify_rejects_other_process() {
        assert_eq!(
            classify_setpriority_target(PRIO_PROCESS, 456, 123),
            SetPriorityTarget::UnsupportedProcess
        );
    }

    #[test]
    fn classify_rejects_unsupported_scope_and_invalid_scope() {
        assert_eq!(
            classify_setpriority_target(PRIO_PGRP, 0, 123),
            SetPriorityTarget::UnsupportedScope
        );
        assert_eq!(
            classify_setpriority_target(PRIO_USER, 0, 123),
            SetPriorityTarget::UnsupportedScope
        );
        assert_eq!(
            classify_setpriority_target(999999, 0, 123),
            SetPriorityTarget::InvalidScope
        );
    }
}
