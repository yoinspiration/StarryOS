#!/usr/bin/env sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "usage: $0 <serial-log-file>"
    exit 1
fi
log_file="$1"
if [ ! -f "$log_file" ]; then
    echo "error: file not found: $log_file"
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
    print "== Global Per-CPU Delta Summary =="
    print "cpu\twindows\tnonzero_windows\tsum_delta_picks\tsum_delta_preempt\tsum_delta_slice\tsum_delta_fallback"
    for (k in windows) {
        if (pref[k] != "ALL") continue
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", cpuid[k], windows[k], nonzero[k]+0, sum_picks[k]+0, sum_preempt[k]+0, sum_slice[k]+0, sum_fallback[k]+0
    }
    print ""
    print "== Case Per-CPU Delta Summary =="
    print "case\tcpu\twindows\tnonzero_windows\tsum_delta_picks\tsum_delta_preempt\tsum_delta_slice\tsum_delta_fallback"
    has_case = 0
    for (k in windows) {
        if (index(pref[k], "CASE:") != 1) continue
        has_case = 1
        case_name = substr(pref[k], 6)
        printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", case_name, cpuid[k], windows[k], nonzero[k]+0, sum_picks[k]+0, sum_preempt[k]+0, sum_slice[k]+0, sum_fallback[k]+0
    }
    if (!has_case) print "(no case markers found in log)"
}
' "$log_file"
