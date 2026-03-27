#!/bin/sh
# Smoke test for setpriority/getpriority syscall semantics.
# Run inside StarryOS guest shell.
#
# Coverage:
# - PRIO_PROCESS path via renice for current/target pid
# - boundary nice values: -20, 0, 19
# - invalid nice value
# - unsupported scopes represented by missing process / tool behavior

set -eu

echo "[prio-smoke] start"
killall yes 2>/dev/null || true

yes > /dev/null & pid=$!
echo "[prio-smoke] target pid=${pid}"

echo "[prio-smoke] apply boundary values (-20, 0, 19)"
renice -n -20 "${pid}"
renice -n 0 "${pid}"
renice -n 19 "${pid}"

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

killall yes 2>/dev/null || true
echo "[prio-smoke] done"
