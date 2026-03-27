#!/bin/sh
# Smoke test for setpriority/getpriority syscall semantics.
# Run inside StarryOS guest shell.
#
# Coverage:
# - PRIO_PROCESS path via renice for target pid
# - boundary nice values: -20, 0, 19
# - set->get consistency check via renice "old priority"
# - invalid nice value and missing pid paths

set -eu

echo "[prio-smoke] start"
killall yes 2>/dev/null || true

yes > /dev/null & pid=$!
echo "[prio-smoke] target pid=${pid}"

check_old_new() {
    expected_old="$1"
    set_to="$2"
    out="$(renice -n "${set_to}" "${pid}" 2>&1 || true)"
    echo "${out}"
    echo "${out}" | grep -q "old priority ${expected_old}" || {
        echo "[prio-smoke] ERROR: expected old priority ${expected_old}, got: ${out}"
        killall yes 2>/dev/null || true
        exit 1
    }
    echo "${out}" | grep -q "new priority ${set_to}" || {
        echo "[prio-smoke] ERROR: expected new priority ${set_to}, got: ${out}"
        killall yes 2>/dev/null || true
        exit 1
    }
}

echo "[prio-smoke] apply boundary values (-20, 0, 19) and verify set/get consistency"
check_old_new 0 -20
check_old_new -20 0
check_old_new 0 19

echo "[prio-smoke] invalid value should fail"
if renice -n 40 "${pid}"; then
    echo "[prio-smoke] ERROR: invalid nice unexpectedly succeeded"
    killall yes 2>/dev/null || true
    exit 1
fi

echo "[prio-smoke] missing pid should fail"
if renice -n 5 999999; then
    echo "[prio-smoke] ERROR: missing pid unexpectedly succeeded"
    killall yes 2>/dev/null || true
    exit 1
fi

echo "[prio-smoke] recover with a valid value after failures"
check_old_new 19 5

killall yes 2>/dev/null || true
echo "[prio-smoke] done"
