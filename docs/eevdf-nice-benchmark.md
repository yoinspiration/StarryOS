# EEVDF + nice Benchmark Notes

## Scope

This document describes a **reproducible latency experiment** for StarryOS when using an
EEVDF-based scheduler together with `nice` (`setpriority`): whether lowering background CPU
priority reduces interference on a short foreground command (`ls`).

Informal introduction to EEVDF concepts (vruntime, eligibility, deadlines; Chinese):
[`eevdf-concept.md`](./eevdf-concept.md).

Two scheduler variants exist in-tree:

| Feature | Scheduler | Default in `kernel/Cargo.toml`? |
| --- | --- | --- |
| `sched-eevdf` | Per-task EEVDF (`EevdfScheduler` / `EevdfEntity`) | **Yes** (current default) |
| `sched-eevdf-class` | Class-weighted EEVDF (`EevdfClassScheduler`) | No (opt-in at build time) |

The **guest workload and scripts below apply to both**; only **kernel log lines and optional
stats APIs** differ (see [Scheduler observability](#scheduler-observability)).

## Environment (repro checklist)

- **Platform**: `riscv64-qemu-virt` (typical; adjust `ARCH` if you use another port).
- **Build**: `release` kernel image used by `make run` / `make ci-test` (see repo `Makefile`).
- **Scheduler**: Match your build:
  - Default checkout: `sched-eevdf` (per-task EEVDF).
  - For class-only sections: enable `sched-eevdf-class` in `kernel/Cargo.toml` (and disable
    conflicting scheduler features) then rebuild.
- **Load**: `4` background `yes` processes (override with `LOAD=…` in the regression script).

### Host: build and run

From the repository root:

```sh
make ARCH=riscv64 build    # or your target
make ARCH=riscv64 run      # interactive; or: make ARCH=riscv64 ci-test
```

Ensure a rootfs/disk image is available per project docs (`make rootfs` if needed).

### Host: unit tests (algorithm smoke, no QEMU)

```sh
cargo test -p axsched -- --nocapture
```

Validates `EevdfScheduler` / `EevdfClassScheduler` behavior in isolation on the host.

## Workload

Two scenarios with the same foreground sample count (`N`):

1. **base**: `LOAD` background `yes` tasks at default priority.
2. **nice19**: same with `nice -n 19 yes`.

Foreground probe (measures wall time of `ls` only; stderr of `time` holds the `%e` values):

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

### Regression automation

Canonical script in the repo:

- `scripts/bench-regression-eevdf.sh`

Guest does not mount host `9p` in the current kernel path; copy the script into the guest and run locally:

```sh
# Example: copy file content to /root/bench-regression-eevdf.sh on the guest, then:
chmod +x /root/bench-regression-eevdf.sh

# Default: LOAD=4, runs N=50 and N=200 for base + nice19, writes TSV + markdown table
/root/bench-regression-eevdf.sh

# Optional: more background tasks
LOAD=6 /root/bench-regression-eevdf.sh

# Optional: customize sample counts (comma-separated)
SAMPLES=30,100 /root/bench-regression-eevdf.sh

# Optional: run a second foreground probe (separate result files by probe name)
PROBE_NAME=busybox_sha256 PROBE_CMD='sha256sum /bin/busybox >/dev/null' /root/bench-regression-eevdf.sh

# After intentional scheduler tuning, refresh stored baseline for compare mode
BASELINE_MODE=refresh /root/bench-regression-eevdf.sh
```

Artifacts (inside guest):

| Path | Contents |
| --- | --- |
| `/root/bench-results/<probe>-latest.tsv` | Latest raw percentile summary |
| `/root/bench-results/<probe>-latest-table.md` | Markdown table (paste into this doc if desired) |
| `/root/bench-results/<probe>-baseline.tsv` | Comparison baseline for `BASELINE_MODE=check` |
| `/root/bench-results/<probe>-history.tsv` | Timestamped archive rows |

`<probe>` defaults to `ls` and can be overridden by `PROBE_NAME`.

Quick percentile summary without the full script (same math as the script’s `calc_stats`):

```sh
sort -n /root/ls_base.txt | awk '{a[++n]=$1} END{printf("base N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
sort -n /root/ls_nice19.txt | awk '{a[++n]=$1} END{printf("nice19 N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
```

### What to expect

- **Absolute** times (seconds) depend on QEMU version, host load, `smp`, and disk image; do not
  expect byte-identical numbers across machines.
- **Relative** behavior: with a working nice→weight path, **nice19** should usually show **lower**
  `p95` / `p99` / `max` for `ls` than **base** under heavy `yes` load. If both are similar, check
  that background tasks actually run at different nice values (`getpriority` / `ps` if available).

## Example observed results (historical)

> The table below is a **sample** from an earlier run (EEVDF-class-focused era). Treat as
> illustration only; **re-run the script on your machine** for current numbers.

**Quick sample (N=50):**

- `base N=50 p50=0.640 p95=0.840 p99=0.850 max=0.850`
- `nice19 N=50 p50=0.050 p95=0.060 p99=0.070 max=0.080`

**Stability stress (N=200, `ls`):**

| Scenario | N | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| base | 50 | 0.630 | 0.630 | 0.850 | 0.850 |
| nice19 | 50 | 0.050 | 0.050 | 0.050 | 0.060 |
| base | 200 | 0.630 | 0.630 | 0.850 | 0.860 |
| nice19 | 200 | 0.050 | 0.060 | 0.060 | 0.060 |

## Scheduler observability

### Per-task EEVDF (`sched-eevdf`, default)

- There are **no** `eevdf-class stats: …` log lines; class share ratios do not apply.
- `axtask` APIs `set_scheduler_stats_config` / `scheduler_stats` / `scheduler_window_stats` are
  **not** compiled in (they are gated on `sched-eevdf-class`).
- Validation is primarily: **host** `cargo test -p axsched`, plus **guest** behavior under load
  (this benchmark).

### EEVDF-class (`sched-eevdf-class`, optional build)

When enabled, the class scheduler exports stats via `info` logs, for example:

- `eevdf-class stats: picks=[...,...,...] ticks=[...,...,...] share(i/n/b)=.../.../...`

`share(i/n/b)` uses a fixed recent window (`STATS_LOG_INTERVAL_TICKS = 256`) and resets after each
emission so the share reflects current behavior rather than lifetime totals.

Example shell recipe to **perturb** class shares (interactive tier may require negative nice support):

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

#### Class share validation (window stats, optional)

With `LOG=info` and `sched-eevdf-class`, a three-stage run can be used to compare measured window
shares to nominal class weights (`interactive:normal:background = 8:4:1`):

1. `background` only (`nice -n 19 yes` ×2)
2. `background` + `normal` (+ default `yes` ×2)
3. `background` + `normal` + `interactive` (+ `nice -n -10 yes` ×2)

Example historical observation:

- Background only: `share(i/n/b)` ≈ `0% / 0% / 100%`
- Background + Normal: ≈ `0% / 80% / 20%`
- All three: ≈ `61% / 31% / 8%` (close to `8:4:1` theoretical split)

### EEVDF-class stats APIs (only with `sched-eevdf-class`)

- Scheduler core: `set_stats_config(enabled, window_ticks)`, `stats()`, `window_stats()`.
- Task layer (`axtask`): `set_scheduler_stats_config`, `scheduler_stats`, `scheduler_window_stats`.

Default when the feature is enabled: stats on, window `256` ticks.

Log lines may include both window and cumulative fields (`window_*` vs `cumulative_*`).

## PRIO_PROCESS (non-current pid) validation

Functional checks for `setpriority` / `getpriority` on arbitrary processes:

1. Spawn two background processes; note `pid1`, `pid2`.
2. `renice -n 19 $pid1` and `renice -n -10 $pid2` (non-current targets).
3. Error paths: invalid nice `renice -n 40 $pidx`; missing pid `renice -n 5 999999`.

Expected: valid updates succeed; invalid nice → `setpriority: Invalid argument`; missing pid →
`getpriority: No such process` (wording may vary slightly).

## Syscall support matrix (current stage)

Scope is kept explicit:

- **Supported**: `PRIO_PROCESS` (current pid `0` or explicit pid, with permission rules).
- **Rejected**: `PRIO_PGRP` / `PRIO_USER` → `OperationNotPermitted` (`EPERM`).

| Syscall | which | who | Result | errno |
| --- | --- | --- | --- | --- |
| `setpriority` | `PRIO_PROCESS` | `0` | set current process nice | `0` |
| `setpriority` | `PRIO_PROCESS` | valid `pid` | set target (permission checked) | `0` |
| `setpriority` | `PRIO_PROCESS` | missing `pid` | reject | `NoSuchProcess` (`ESRCH`) |
| `setpriority` | `PRIO_PROCESS` | any | `prio` not in `[-20, 19]` | `InvalidInput` (`EINVAL`) |
| `setpriority` | `PRIO_PGRP` / `PRIO_USER` | any | not supported | `EPERM` |
| `setpriority` | invalid `which` | any | invalid selector | `EINVAL` |
| `getpriority` | `PRIO_PROCESS` | `0` / valid `pid` | read nice (encoded) | value |
| `getpriority` | `PRIO_PROCESS` | missing `pid` | reject | `ESRCH` |
| `getpriority` | `PRIO_PGRP` / `PRIO_USER` | any | not supported | `EPERM` |
| `getpriority` | invalid `which` | any | invalid selector | `EINVAL` |

### getpriority encoding (Linux-compatible)

- Returned value = `20 - nice` (e.g. nice `-20` → `40`, nice `0` → `20`, nice `19` → `1`).
- Boundary coverage: `scripts/priority-syscall-smoke.sh` (guest).

### Other scripts (guest)

- `scripts/priority-syscall-smoke.sh` — boundary nice values and error paths.
- `scripts/priority-permission-regression.sh` — self / same-uid / cross-uid / root (see script for
  backends: `setpriv`, Python, `runuser`/`su`).

## Conclusion

- **`nice` is expected to matter** for foreground latency under CPU-heavy background load whenever
  priority maps into the active scheduler’s weights (per-task EEVDF and EEVDF-class both use
  nice-derived weights in-tree).
- Use **`scripts/bench-regression-eevdf.sh`** for repeatable before/after tables; refresh
  **baseline** only when behavior changes intentionally.

## Current limitations

- No host `9p` share: keep benchmark scripts and outputs under **guest** paths (e.g. `/root/…`).
- `setpriority` is intentionally minimal (`PRIO_PROCESS` only; `PRIO_PGRP`/`PRIO_USER` → `EPERM`).
- One process-wide nice for all threads of a process in the current model.
- Short runs and one workload (`ls`); not publication-grade without more samples and machines.
