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
    syscall::sys::sys_geteuid,
    task::{get_process_data, tasks, AsThread},
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

fn apply_nice_to_process(pid: u32, prio: i32) -> AxResult<bool> {
    let mut applied = false;
    for task in tasks() {
        let Some(thr) = task.try_as_thread() else {
            continue;
        };
        if thr.proc_data.proc.pid() as u32 != pid {
            continue;
        }
        if !axtask::set_priority_for_task(&task, prio as isize) {
            return Ok(false);
        }
        applied = true;
    }
    Ok(applied)
}

fn nice_to_getpriority_value(nice: i32) -> isize {
    // Keep Linux-compatible return encoding used by this kernel path.
    // Nice range [-20, 19] maps to [40, 1].
    (20 - nice) as isize
}

fn has_setpriority_permission(
    curr_pid: u32,
    target_pid: u32,
    curr_euid: u32,
    target_euid: u32,
) -> bool {
    // Linux-like minimal rule:
    // - a process can always adjust its own priority
    // - privileged user (euid == 0) can adjust others
    // - same euid can adjust others (phase-1 permission model)
    curr_pid == target_pid || curr_euid == 0 || curr_euid == target_euid
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
            // Supported scope in current stage: process only.
            // `who == 0` means current process; otherwise target pid.
            let proc_data = get_process_data(who)?;
            Ok(nice_to_getpriority_value(proc_data.nice()))
        }
        // Keep unsupported scopes consistent with sys_setpriority.
        PRIO_PGRP | PRIO_USER => Err(AxError::OperationNotPermitted),
        _ => Err(AxError::InvalidInput),
    }
}

pub fn sys_setpriority(which: u32, who: u32, prio: i32) -> AxResult<isize> {
    debug!("sys_setpriority <= which: {which}, who: {who}, prio: {prio}");

    // Current semantic boundary:
    // - only supports PRIO_PROCESS
    // - supports current or specified process by pid
    // Other scopes return OperationNotPermitted for now.
    if !(-20..=19).contains(&prio) {
        return Err(AxError::InvalidInput);
    }

    let curr_pid = current().as_thread().proc_data.proc.pid() as u32;
    let curr_euid = sys_geteuid()? as u32;
    match classify_setpriority_target(which, who, curr_pid) {
        SetPriorityTarget::CurrentProcess => {
            // On Linux, `nice` may pass `who = 0` or `who = getpid()`.
            let curr_task = current();
            let curr = curr_task.as_thread();
            let pid = curr.proc_data.proc.pid() as u32;
            curr.proc_data.set_nice(prio);
            if apply_nice_to_process(pid, prio)? {
                Ok(0)
            } else {
                Err(AxError::InvalidInput)
            }
        }
        SetPriorityTarget::UnsupportedProcess => {
            // Minimal support for PRIO_PROCESS + specified pid.
            let proc_data = get_process_data(who)?;
            if !has_setpriority_permission(curr_pid, who, curr_euid, proc_data.euid()) {
                return Err(AxError::OperationNotPermitted);
            }
            proc_data.set_nice(prio);
            if apply_nice_to_process(who, prio)? {
                Ok(0)
            } else {
                Err(AxError::InvalidInput)
            }
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

    #[test]
    fn getpriority_value_encoding_matches_nice_range() {
        assert_eq!(nice_to_getpriority_value(-20), 40);
        assert_eq!(nice_to_getpriority_value(0), 20);
        assert_eq!(nice_to_getpriority_value(19), 1);
    }

    #[test]
    fn setpriority_permission_allows_self_or_root() {
        assert!(has_setpriority_permission(100, 100, 1000, 2000));
        assert!(has_setpriority_permission(100, 200, 0, 2000));
        assert!(has_setpriority_permission(100, 200, 1000, 1000));
        assert!(!has_setpriority_permission(100, 200, 1000, 2000));
    }
}
