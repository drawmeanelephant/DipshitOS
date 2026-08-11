#!/usr/bin/env bash
# verify-vz aggregate sweep (the justfile recipe, since `just` may not be
# installed): serial takeover + the 28 live gates + the net-tx gate.
# Usage: sweep-vz.sh <log> <start> <end>   (1-based gate index; the default
# start=1 end=28 runs everything). Gates are logged with G<n>-PASS/FAIL.
set -u
LOG="${1:-artifacts/live-net-tx-vz-sweep.log}"
START="${2:-1}"
END="${3:-28}"
n=0
run_gate() {
    n=$((n + 1))
    local name="$1"
    echo "--- gate $n: $name" >> "$LOG"
    if [ "$name" = "zig-build-run" ]; then
        zig build run >> "$LOG" 2>&1
    else
        bash "tools/$name.sh" >> "$LOG" 2>&1
    fi
    local rc=$?
    if [ "$rc" = 0 ]; then
        echo "G$n-PASS $name" >> "$LOG"
    else
        echo "G$n-FAIL $name (rc=$rc)" >> "$LOG"
    fi
}
GATES="zig-build-run verify-bad-handoff verify-marker verify-nvram-console verify-host-console verify-live-transcript verify-live-fs verify-live-gfs verify-live-timer verify-live-tasks verify-live-userspace verify-live-svc verify-live-uaccess verify-live-addrspaces verify-live-lifecycle verify-live-exec verify-live-args verify-live-procs verify-live-concurrent verify-live-long-lived verify-live-kill verify-live-sleep verify-live-entropy verify-live-reboot verify-live-ipc verify-live-procs-syscall verify-live-scale verify-live-wait verify-live-net-tx"
i=0
for g in $GATES; do
    i=$((i + 1))
    if [ "$i" -ge "$START" ] && [ "$i" -le "$END" ]; then
        run_gate "$g"
    fi
done
echo "SWEEP-DONE gates=$n (range $START..$END)" >> "$LOG"
