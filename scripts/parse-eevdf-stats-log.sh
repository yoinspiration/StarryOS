#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <serial-log-file>"
    echo ""
    echo "optional env:"
    echo "  TICKS_PER_SEC   timer tick frequency (default: 100)"
    echo "  INTERVAL_TICKS  eevdf stats log interval ticks (default: 256)"
    exit 1
fi
log_file="$1"
if [ ! -f "$log_file" ]; then
    echo "error: file not found: $log_file"
    exit 1
fi
ticks_per_sec="${TICKS_PER_SEC:-100}"
interval_ticks="${INTERVAL_TICKS:-256}"
case "$ticks_per_sec" in
    ''|*[!0-9]*)
        echo "error: TICKS_PER_SEC must be a positive integer"
        exit 1
        ;;
esac
case "$interval_ticks" in
    ''|*[!0-9]*)
        echo "error: INTERVAL_TICKS must be a positive integer"
        exit 1
        ;;
esac
if [ "$ticks_per_sec" -eq 0 ] || [ "$interval_ticks" -eq 0 ]; then
    echo "error: TICKS_PER_SEC and INTERVAL_TICKS must be > 0"
    exit 1
fi

awk '
function extract_value(text, key,   re, s) {
    re = key "=[0-9]+"
    if (match(text, re)) {
        s = substr(text, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", s)
        return s + 0
    }
    return 0
}
function add_stats(prefix, cpu, picks, preempt, slice, fallback,   k) {
    k = prefix SUBSEP cpu
    windows[k] += 1
    if (picks > 0 || preempt > 0 || slice > 0 || fallback > 0) nonzero[k] += 1
    sum_picks[k] += picks
    sum_preempt[k] += preempt
    sum_slice[k] += slice
    sum_fallback[k] += fallback
    pref[k] = prefix
    cpuid[k] = cpu
}
function print_latency_hint(windows, picks, tps, win_ticks,   total_ms, avg_ms, hz) {
    total_ms = windows * win_ticks * 1000.0 / tps
    if (picks > 0) {
        avg_ms = total_ms / picks
        hz = picks * 1000.0 / total_ms
        printf "\t(estimated) avg_switch_interval_ms=%.3f\t(estimated) switch_rate_hz=%.2f", avg_ms, hz
    } else {
        printf "\t(estimated) avg_switch_interval_ms=inf\t(estimated) switch_rate_hz=0.00"
    }
}
BEGIN { current_case = "" }
{
    gsub(/\r/, "", $0)
    if (index($0, "[bench-marker] case-start ") > 0) {
        current_case = $0
        sub(/^.*\[bench-marker\] case-start /, "", current_case)
        gsub(/\r/, "", current_case)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_case)
        next
    }
    if (index($0, "[bench-marker] case-end ") > 0) {
        current_case = ""
        next
    }
    if (match($0, /eevdf stats cpu[0-9]+:/)) {
        cpu_text = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", cpu_text)
        cpu = cpu_text + 0
        picks = preempt = slice = fallback = 0
        if (match($0, /delta\[[^]]+\]/)) {
            d = substr($0, RSTART, RLENGTH)
            picks = extract_value(d, "picks")
            preempt = extract_value(d, "preempt")
            slice = extract_value(d, "slice_expired")
            fallback = extract_value(d, "fallback")
        }
        add_stats("ALL", cpu, picks, preempt, slice, fallback)
        if (current_case != "") add_stats("CASE:" current_case, cpu, picks, preempt, slice, fallback)
    }
}
END {
    printf "== Config ==\n"
    printf "ticks_per_sec=%d\tinterval_ticks=%d\twindow_ms=%.3f\n", tps, win_ticks, (win_ticks * 1000.0 / tps)
    print ""

    print "== Global Per-CPU Delta Summary =="
    print "cpu\twindows\tnonzero_windows\tsum_delta_picks\tsum_delta_preempt\tsum_delta_slice\tsum_delta_fallback\tavg_switch_interval_ms(estimated)\tswitch_rate_hz(estimated)"
    for (k in windows) {
        if (pref[k] != "ALL") continue
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d", cpuid[k], windows[k], nonzero[k]+0, sum_picks[k]+0, sum_preempt[k]+0, sum_slice[k]+0, sum_fallback[k]+0
        print_latency_hint(windows[k], sum_picks[k]+0, tps, win_ticks)
        printf "\n"
    }
    print ""
    print "== Case Per-CPU Delta Summary =="
    print "case\tcpu\twindows\tnonzero_windows\tsum_delta_picks\tsum_delta_preempt\tsum_delta_slice\tsum_delta_fallback\tavg_switch_interval_ms(estimated)\tswitch_rate_hz(estimated)"
    has_case = 0
    for (k in windows) {
        if (index(pref[k], "CASE:") != 1) continue
        has_case = 1
        case_name = substr(pref[k], 6)
        printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d", case_name, cpuid[k], windows[k], nonzero[k]+0, sum_picks[k]+0, sum_preempt[k]+0, sum_slice[k]+0, sum_fallback[k]+0
        print_latency_hint(windows[k], sum_picks[k]+0, tps, win_ticks)
        printf "\n"
    }
    if (!has_case) print "(no case markers found in log)"
}
' tps="$ticks_per_sec" win_ticks="$interval_ticks" "$log_file"
