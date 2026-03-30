#!/bin/sh
# Permission regression for setpriority/getpriority semantics.
# Run inside StarryOS guest shell as root.
#
# Coverage (Issue 2):
# - self: same process owner updates priority
# - same uid: non-root updates another process owned by same uid
# - different uid: non-root updates process owned by different uid (must fail)
# - root override: root updates process owned by different uid (must pass)
#
# Identity-switch backend order:
# 1) setpriv (preferred, no Python dependency)
# 2) Python os.setuid()
# 3) runuser/su (requires uid -> username mapping in /etc/passwd)

set -eu

UID_A="${UID_A:-1001}"
UID_B="${UID_B:-1002}"
BACKEND="${BACKEND:-auto}" # auto | setpriv | python | user-switch

RUN_AS_BACKEND=""
PYTHON_BIN=""
USER_SWITCH_BIN=""

uid_to_user() {
    uid="$1"
    awk -F: -v uid="$uid" '$3 == uid { print $1; exit }' /etc/passwd 2>/dev/null || true
}

setpriv_supports_uid_switch() {
    if ! command -v setpriv >/dev/null 2>&1; then
        return 1
    fi
    # BusyBox ships a minimal setpriv without --reuid/--regid; help text checks
    # can false-positive. Require a successful dry-run (util-linux behavior).
    if setpriv --reuid 0 --regid 0 true 2>/dev/null; then
        return 0
    fi
    return 1
}

select_backend() {
    if [ "$BACKEND" != "auto" ]; then
        case "$BACKEND" in
            setpriv)
                if setpriv_supports_uid_switch; then
                    RUN_AS_BACKEND="setpriv"
                    return 0
                fi
                ;;
            python)
                if command -v python3 >/dev/null 2>&1; then
                    RUN_AS_BACKEND="python"
                    PYTHON_BIN="python3"
                    return 0
                fi
                if command -v python >/dev/null 2>&1; then
                    RUN_AS_BACKEND="python"
                    PYTHON_BIN="python"
                    return 0
                fi
                ;;
            user-switch)
                if command -v runuser >/dev/null 2>&1; then
                    RUN_AS_BACKEND="user-switch"
                    USER_SWITCH_BIN="runuser"
                    return 0
                fi
                if command -v su >/dev/null 2>&1; then
                    RUN_AS_BACKEND="user-switch"
                    USER_SWITCH_BIN="su"
                    return 0
                fi
                ;;
            *)
                echo "[prio-perm] ERROR: invalid BACKEND=${BACKEND}"
                echo "[prio-perm] expected one of: auto|setpriv|python|user-switch"
                exit 1
                ;;
        esac
        echo "[prio-perm] ERROR: forced backend '${BACKEND}' is unavailable in guest"
        exit 1
    fi

    if setpriv_supports_uid_switch; then
        RUN_AS_BACKEND="setpriv"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        RUN_AS_BACKEND="python"
        PYTHON_BIN="python3"
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        RUN_AS_BACKEND="python"
        PYTHON_BIN="python"
        return 0
    fi
    if command -v runuser >/dev/null 2>&1; then
        RUN_AS_BACKEND="user-switch"
        USER_SWITCH_BIN="runuser"
        return 0
    fi
    if command -v su >/dev/null 2>&1; then
        RUN_AS_BACKEND="user-switch"
        USER_SWITCH_BIN="su"
        return 0
    fi
    return 1
}

PIDS=""
cleanup() {
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
    done
    killall yes 2>/dev/null || true
}
trap cleanup EXIT INT TERM

spawn_yes_as_uid() {
    uid="$1"
    case "$RUN_AS_BACKEND" in
        setpriv)
            setpriv --reuid "$uid" --regid "$uid" --clear-groups \
                sh -c 'yes >/dev/null 2>&1 & echo $!'
            ;;
        python)
            "$PYTHON_BIN" - "$uid" <<'PY'
import os
import sys
import subprocess

uid = int(sys.argv[1])
os.setuid(uid)
p = subprocess.Popen(["yes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(p.pid)
PY
            ;;
        user-switch)
            user="$(uid_to_user "$uid")"
            if [ -z "$user" ]; then
                echo "[prio-perm] ERROR: uid ${uid} has no username mapping in /etc/passwd"
                exit 1
            fi
            if [ "$USER_SWITCH_BIN" = "runuser" ]; then
                runuser -u "$user" -- sh -c 'yes >/dev/null 2>&1 & echo $!'
            else
                su -s /bin/sh "$user" -c 'yes >/dev/null 2>&1 & echo $!'
            fi
            ;;
        *)
            echo "[prio-perm] ERROR: no backend selected"
            exit 1
            ;;
    esac
}

run_renice_as_uid() {
    actor_uid="$1"
    target_pid="$2"
    new_nice="$3"
    case "$RUN_AS_BACKEND" in
        setpriv)
            setpriv --reuid "$actor_uid" --regid "$actor_uid" --clear-groups \
                renice -n "$new_nice" "$target_pid"
            ;;
        python)
            "$PYTHON_BIN" - "$actor_uid" "$target_pid" "$new_nice" <<'PY'
import os
import sys
import subprocess

uid = int(sys.argv[1])
pid = sys.argv[2]
nice = sys.argv[3]
os.setuid(uid)
proc = subprocess.run(
    ["renice", "-n", nice, pid],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
print(proc.stdout, end="")
sys.exit(proc.returncode)
PY
            ;;
        user-switch)
            user="$(uid_to_user "$actor_uid")"
            if [ -z "$user" ]; then
                echo "[prio-perm] ERROR: uid ${actor_uid} has no username mapping in /etc/passwd"
                exit 1
            fi
            if [ "$USER_SWITCH_BIN" = "runuser" ]; then
                runuser -u "$user" -- renice -n "$new_nice" "$target_pid"
            else
                su -s /bin/sh "$user" -c "renice -n ${new_nice} ${target_pid}"
            fi
            ;;
        *)
            echo "[prio-perm] ERROR: no backend selected"
            exit 1
            ;;
    esac
}

if ! select_backend; then
    echo "[prio-perm] ERROR: no usable identity-switch backend found"
    echo "[prio-perm] require one of: setpriv / python3 / python / runuser / su"
    exit 1
fi

echo "[prio-perm] start (uid_a=${UID_A}, uid_b=${UID_B}, backend=${RUN_AS_BACKEND}, requested=${BACKEND})"
killall yes 2>/dev/null || true

pid_a_self="$(spawn_yes_as_uid "$UID_A")"
pid_a_peer="$(spawn_yes_as_uid "$UID_A")"
pid_b="$(spawn_yes_as_uid "$UID_B")"
PIDS="${pid_a_self} ${pid_a_peer} ${pid_b}"

echo "[prio-perm] pids: self=${pid_a_self} same_uid=${pid_a_peer} diff_uid=${pid_b}"

echo "[prio-perm] case self (uid=${UID_A} -> pid=${pid_a_self}) should pass"
run_renice_as_uid "$UID_A" "$pid_a_self" 5 >/tmp/prio-perm-self.out

echo "[prio-perm] case same uid (uid=${UID_A} -> pid=${pid_a_peer}) should pass"
run_renice_as_uid "$UID_A" "$pid_a_peer" 7 >/tmp/prio-perm-same.out

echo "[prio-perm] case different uid (uid=${UID_A} -> pid=${pid_b}) should fail with EPERM"
if run_renice_as_uid "$UID_A" "$pid_b" 9 >/tmp/prio-perm-diff.out 2>&1; then
    echo "[prio-perm] ERROR: different-uid update unexpectedly succeeded"
    exit 1
fi
diff_out="$(cat /tmp/prio-perm-diff.out)"
case "$diff_out" in
    *Operation\ not\ permitted*|*Permission\ denied*)
        ;;
    *)
        echo "[prio-perm] ERROR: expected permission error, got: ${diff_out}"
        exit 1
        ;;
esac

echo "[prio-perm] case root override (uid=0 -> pid=${pid_b}) should pass"
run_renice_as_uid 0 "$pid_b" 11 >/tmp/prio-perm-root.out

echo "[prio-perm] PASS: self/same-uid/different-uid/root scenarios validated"
