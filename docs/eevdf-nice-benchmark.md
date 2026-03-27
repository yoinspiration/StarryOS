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
  - Permission rule is currently minimal: self process or privileged user (`euid == 0`) can update.
  - `PRIO_PGRP` and `PRIO_USER` return `OperationNotPermitted`.
- `getpriority` remains partially implemented for compatibility:
  - `PRIO_PROCESS` now returns the stored process nice (using this kernel path's return encoding).
  - `PRIO_PGRP`/`PRIO_USER` are not yet semantically aligned with the minimal `setpriority` boundary.
  - A future update should return effective nice values and unify scope handling.
- This benchmark is single-machine and short-run (`N=50`); larger samples and additional workloads
  are recommended for publication-grade claims.
