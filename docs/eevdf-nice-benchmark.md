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

Summary command:

```sh
sort -n /root/ls_base.txt | awk '{a[++n]=$1} END{printf("base N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
sort -n /root/ls_nice19.txt | awk '{a[++n]=$1} END{printf("nice19 N=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[int((n-1)*0.99)+1], a[n])}'
```

## Observed Results

- `base N=50 p50=0.640 p95=0.840 p99=0.850 max=0.850`
- `nice19 N=50 p50=0.050 p95=0.060 p99=0.070 max=0.080`

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

## Conclusion

`nice` is effective with the current EEVDF-class integration. Lowering background task priority
to `nice=19` significantly improves foreground latency for `ls` in this setup.

## Current Limitations

- `setpriority` support is intentionally minimal:
  - Only `PRIO_PROCESS` is supported.
  - Only current process update is supported (`who == 0` or current pid).
  - `PRIO_PGRP` and `PRIO_USER` return `OperationNotPermitted`.
- `getpriority` remains partially implemented for compatibility:
  - `PRIO_PROCESS` currently returns a fixed placeholder value after target existence validation.
  - `PRIO_PGRP`/`PRIO_USER` are not yet semantically aligned with the minimal `setpriority` boundary.
  - A future update should return effective nice values and unify scope handling.
- This benchmark is single-machine and short-run (`N=50`); larger samples and additional workloads
  are recommended for publication-grade claims.
