# EEVDF Class + nice Benchmark Notes

## Scope

This note records a quick latency experiment for the EEVDF-class scheduler path in StarryOS,
focused on whether `nice` (`setpriority`) can effectively reduce background CPU pressure on
interactive commands.

## Environment

- Platform: `riscv64-qemu-virt`
- Build profile: `release`
- Scheduler feature: `sched-eevdf-class`
- Load generator: `yes > /dev/null`
- Foreground probe: `ls`

## Workload

Two runs were executed with the same foreground probe count (`N=50`):

1. **Base**: 4 background `yes` tasks with default priority.
2. **nice19**: 4 background `yes` tasks started with `nice -n 19`.

Commands (inside StarryOS shell):

```sh
killall yes 2>/dev/null
for i in 1 2 3 4; do yes > /dev/null & done
sleep 1
for i in $(seq 1 50); do /usr/bin/time -f "%e" ls >/dev/null; done > /root/ls_base.txt 2>&1
killall yes 2>/dev/null

for i in 1 2 3 4; do nice -n 19 yes > /dev/null & done
sleep 1
for i in $(seq 1 50); do /usr/bin/time -f "%e" ls >/dev/null; done > /root/ls_nice19.txt 2>&1
killall yes 2>/dev/null
```

## Regression Automation (Issue 5)

Canonical script path in repo:

- `scripts/bench-regression-eevdf.sh`

Because host sharing (`9p`) is not available in the current kernel path, run a guest-local copy:

```sh
# after copying script content to guest local path:
chmod +x /root/bench-regression-eevdf.sh

# one command: run N=50 + N=200, base + nice19, emit table, compare baseline
/root/bench-regression-eevdf.sh

# optional: refresh baseline after intentional tuning
BASELINE_MODE=refresh /root/bench-regression-eevdf.sh
```

Generated artifacts (inside guest):

- `/root/bench-results/latest.tsv` (latest raw metrics)
- `/root/bench-results/latest-table.md` (markdown result table)
- `/root/bench-results/baseline.tsv` (comparison baseline)
- `/root/bench-results/history.tsv` (timestamped archive)

Semi-automatic doc update workflow:

1. Run `/root/bench-regression-eevdf.sh`
2. Copy table content from `/root/bench-results/latest-table.md`
3. Replace the "Stability Stress Results" table in this document

Summary command:

```sh
sort -n /root/ls_base.txt | awk '{a[++n]=$1} END{printf("base N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
sort -n /root/ls_nice19.txt | awk '{a[++n]=$1} END{printf("nice19 N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
```

## Observed Results

- `base N=50 p50=0.640 p95=0.840 p99=0.850 max=0.850`
- `nice19 N=50 p50=0.050 p95=0.060 p99=0.070 max=0.080`

## Stability Stress Results (N=200, `ls`)

| Scenario | N | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| base | 50 | 0.630 | 0.630 | 0.850 | 0.850 |
| nice19 | 50 | 0.050 | 0.050 | 0.050 | 0.060 |
| base | 200 | 0.630 | 0.630 | 0.850 | 0.860 |
| nice19 | 200 | 0.050 | 0.060 | 0.060 | 0.060 |

Compared with `base`, the `nice19` run keeps a clear latency advantage at tail metrics
(`p95/p99/max`) at both sample sizes, and no regression is observed in this baseline run.

## Scheduler Stats Observability

The EEVDF-class scheduler exports class-level stats through `info` logs:

- `eevdf-class stats: picks=[...,...,...] ticks=[...,...,...] share(i/n/b)=.../.../...`

`share(i/n/b)` is computed in a fixed recent window (`STATS_LOG_INTERVAL_TICKS = 256`) and
reset after each emission. This makes the share reflect current scheduling behavior rather than
long-lived boot-time accumulation.

Quick load recipe to observe class share changes in StarryOS shell:

```sh
killall yes 2>/dev/null

# background class (nice 19)
for i in 1 2; do nice -n 19 yes > /dev/null & done

# normal class (default nice 0)
for i in 1 2; do yes > /dev/null & done

# interactive class (negative nice, if supported)
for i in 1 2; do nice -n -10 yes > /dev/null & done

sleep 10
killall yes 2>/dev/null
```

If negative nice is not supported in your environment, skip the interactive block and run a
two-class comparison (`normal` + `background`) first.

## Class Share Validation (Window Stats)

A follow-up run was executed with window-based scheduler stats enabled (`LOG=info`):

1. `background` only (`nice -n 19 yes` x2)
2. `background` + `normal` (plus default `yes` x2)
3. `background` + `normal` + `interactive` (plus `nice -n -10 yes` x2)

Observed window-share evolution:

- Background only: `share(i/n/b)` converged to about `0% / 0% / 100%`
- Background + Normal: `share(i/n/b)` moved to about `0% / 80% / 20%`
- Background + Normal + Interactive: `share(i/n/b)` stabilized around `61% / 31% / 8%`

With class weights `interactive:normal:background = 8:4:1`, the theoretical split is:

- interactive: `8 / (8+4+1) = 61.5%`
- normal: `4 / (8+4+1) = 30.8%`
- background: `1 / (8+4+1) = 7.7%`

The measured values closely match the expected ratio, which validates that class-level accounting
and weighted dispatch behavior are working as intended.

## PRIO_PROCESS (non-current pid) Validation

A functional validation was run for `setpriority/getpriority` behavior on non-current processes:

1. Spawn two background processes and capture pids (`pid1`, `pid2`)
2. Apply `renice -n 19 $pid1` and `renice -n -10 $pid2` (non-current targets)
3. Validate error handling with:
   - invalid nice value: `renice -n 40 $pidx`
   - non-existing process: `renice -n 5 999999`

Observed results:

- Non-current target updates succeeded for valid values.
- Invalid priority was rejected with `setpriority: Invalid argument`.
- Missing target was rejected with `getpriority: No such process`.
- Follow-up valid update (`renice -n 5 $pidx`) succeeded.

Conclusion:

- Minimal `PRIO_PROCESS` support for specified pid is functional.
- Basic error-path semantics for invalid input and missing process are preserved.

## Syscall Support Matrix (Current Stage)

Current strategy keeps scope semantics explicit and stable:

- fully support `PRIO_PROCESS`
- consistently reject `PRIO_PGRP`/`PRIO_USER` with `OperationNotPermitted` (`EPERM`)

| Syscall | which | who | Result | errno |
| --- | --- | --- | --- | --- |
| `setpriority` | `PRIO_PROCESS` | `0` | set current process nice | `0` |
| `setpriority` | `PRIO_PROCESS` | valid `pid` | set target process nice (permission checked) | `0` |
| `setpriority` | `PRIO_PROCESS` | missing `pid` | reject target | `NoSuchProcess` (`ESRCH`) |
| `setpriority` | `PRIO_PROCESS` | any | reject `prio` outside `[-20, 19]` | `InvalidInput` (`EINVAL`) |
| `setpriority` | `PRIO_PGRP` | any | not supported in current stage | `OperationNotPermitted` (`EPERM`) |
| `setpriority` | `PRIO_USER` | any | not supported in current stage | `OperationNotPermitted` (`EPERM`) |
| `setpriority` | invalid `which` | any | invalid scope selector | `InvalidInput` (`EINVAL`) |
| `getpriority` | `PRIO_PROCESS` | `0` | read current process nice | encoded value |
| `getpriority` | `PRIO_PROCESS` | valid `pid` | read target process nice | encoded value |
| `getpriority` | `PRIO_PROCESS` | missing `pid` | reject target | `NoSuchProcess` (`ESRCH`) |
| `getpriority` | `PRIO_PGRP` | any | not supported in current stage | `OperationNotPermitted` (`EPERM`) |
| `getpriority` | `PRIO_USER` | any | not supported in current stage | `OperationNotPermitted` (`EPERM`) |
| `getpriority` | invalid `which` | any | invalid scope selector | `InvalidInput` (`EINVAL`) |

### getpriority Value Encoding

Current kernel path uses Linux-compatible encoding:

- returned value = `20 - nice`
- mapping examples:
  - `nice = -20` -> `40`
  - `nice = 0` -> `20`
  - `nice = 19` -> `1`
- boundary values are covered in `scripts/priority-syscall-smoke.sh`

### Syscall Smoke Script

Use `scripts/priority-syscall-smoke.sh` (run inside guest shell) to cover:

- `PRIO_PROCESS` boundary values `-20/0/19`
- invalid value rejection
- missing pid rejection

### Permission Regression Script (Issue 2)

Use `scripts/priority-permission-regression.sh` (run inside guest shell as root) to validate:

- self update: non-root process changes its own target priority
- same uid update: non-root process changes another process with same uid
- different uid update: non-root process changes process with different uid -> `OperationNotPermitted`
- root override: root can change different-uid process priority

The script auto-selects identity-switch backend in this order:

1. `setpriv` (preferred)
2. Python `os.setuid`
3. `runuser` / `su` (needs uid->username mapping in `/etc/passwd`)

Then it exercises `renice` end-to-end for all required permission classes.

Optional backend pinning (for CI or reproducibility):

- `BACKEND=auto` (default)
- `BACKEND=setpriv`
- `BACKEND=python`
- `BACKEND=user-switch`

## Conclusion

`nice` is effective with the current EEVDF-class integration. Lowering background task priority
to `nice=19` significantly improves foreground latency for `ls` in this setup.

## Current Limitations

- Host directory sharing via `mount -t 9p` is not supported in the current kernel path.
  Use guest-local paths (for example `/root/bench-eevdf-nice.sh`) for benchmark automation.
- `setpriority` support is intentionally minimal:
  - Only `PRIO_PROCESS` is supported.
  - `PRIO_PROCESS` supports current process (`who == 0`) and specified process (`who == pid`).
  - `PRIO_PROCESS` currently applies one process-wide nice to all its threads.
  - Permission rule (phase-2 staged model): self process, same uid, or privileged user (`euid == 0`) can update.
  - `PRIO_PGRP` and `PRIO_USER` return `OperationNotPermitted`.
- `getpriority` currently aligns with the same scope boundary:
  - `PRIO_PROCESS` returns the stored process nice (with `20 - nice` encoding).
  - `PRIO_PGRP` and `PRIO_USER` return `OperationNotPermitted`.
- This benchmark is single-machine and short-run (`N=50`); larger samples and additional workloads
  are recommended for publication-grade claims.

## Scheduler Stats Productization Notes

`EevdfClassScheduler` now exposes configurable observability controls:

- scheduler-core API:
  - `set_stats_config(enabled, window_ticks)` toggles periodic stats logs and sets report window size
  - `stats()` returns cumulative counters
  - `window_stats()` returns in-window counters
- task-layer API (`axtask`, when `sched-eevdf-class` is enabled):
  - `set_scheduler_stats_config(enabled, window_ticks)`
  - `scheduler_stats()`
  - `scheduler_window_stats()`

Default remains: stats enabled + window size `256`, so existing benchmark scripts keep working unchanged.

Log output now contains both window and cumulative views in one line:

- `window_*` fields reflect recent-share movement
- `cumulative_*` fields provide long-horizon trend
