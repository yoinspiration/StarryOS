#!/usr/bin/env sh
# Parse serial log and summarize EEVDF delta activity.
#
# Usage:
#   sh scripts/parse-eevdf-stats-log.sh path/to/serial.log
#
# Output:
#   cpu  windows  nonzero_windows  sum_delta_picks  sum_delta_preempt  sum_delta_slice  sum_delta_fallback

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
{
    # Expected fragment:
    # eevdf stats cpu1: total[...] delta[picks=0 preempt=0 slice_expired=0 fallback=0]
    if (match($0, /eevdf stats cpu[0-9]+:/)) {
        cpu_text = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", cpu_text)
        cpu = cpu_text + 0

        picks = preempt = slice = fallback = 0
        delta_part = ""
        if (match($0, /delta\[[^]]+\]/)) {
            delta_part = substr($0, RSTART, RLENGTH)
        }
        if (delta_part != "") {
            if (match(delta_part, /picks=[0-9]+/)) {
                s = substr(delta_part, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", s)
                picks = s + 0
            }
            if (match(delta_part, /preempt=[0-9]+/)) {
                s = substr(delta_part, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", s)
                preempt = s + 0
            }
            if (match(delta_part, /slice_expired=[0-9]+/)) {
                s = substr(delta_part, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", s)
                slice = s + 0
            }
            if (match(delta_part, /fallback=[0-9]+/)) {
                s = substr(delta_part, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", s)
                fallback = s + 0
            }
        }

        windows[cpu] += 1
        if (picks > 0 || preempt > 0 || slice > 0 || fallback > 0) {
            nonzero[cpu] += 1
        }
        sum_picks[cpu] += picks
        sum_preempt[cpu] += preempt
        sum_slice[cpu] += slice
        sum_fallback[cpu] += fallback
    }
}
END {
    print "cpu\twindows\tnonzero_windows\tsum_delta_picks\tsum_delta_preempt\tsum_delta_slice\tsum_delta_fallback"
    for (c in windows) {
        printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
            c, windows[c], nonzero[c] + 0, sum_picks[c] + 0, sum_preempt[c] + 0, sum_slice[c] + 0, sum_fallback[c] + 0
    }
}
' "$log_file"
