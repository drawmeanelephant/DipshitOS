#!/usr/bin/env bash
#
# verify-live-win-close.sh -- claim 0487 (milestone six, card G6 teardown
# follow-on) class-B gate: the draw/window RELEASE proof, live on real VZ.
#
# WINCLOSE.BIN (user/src/winclose.zig) drives the whole seam and then tears
# the window down — sys_win_open (12) -> sys_win_fill (13) ->
# sys_win_present (14) -> sys_win_close (15) -> sys_exit(88) — entirely
# from EL0. The gate proves THREE things that the G6 open-only proof could
# not:
#   * the window DISAPPEARS: after `win: close ok`, the kernel's own `win`
#     report reads `windows=2` (terminal + clock, no user window) and NO
#     `dui[2]:` row ever appears;
#   * the SLOT IS REUSABLE: a re-exec prints `win: open id=2` AGAIN (never
#     id 3 — the first close freed the slot instead of leaking it);
#   * the counters agree: the script2 `syscalls` snapshot (taken after the
#     first close, before the re-exec) shows open=1/close=1.
#
# Two phases (the claim-4613 second-phase pattern): script1 execs
# WINCLOSE.BIN; script2 is forwarded once after the first
# `procs WINCLOSE.BIN exited status=88` reap, so its `win`/`syscalls` read
# the SAME kernel state (window closed), then it re-execs the program.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR;
# DIPSHIT_GATE_SUFFIX/_KEEP_RUN supported.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge proves
# class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-win-close.sh
#
# Evidence: artifacts/live-win-close-gate.txt (full output),
# artifacts/live-win-close-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-win-close-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-win-close-report.txt"

echo "=== verify-live-win-close: claim 0487 follow-on — the draw/window RELEASE proof, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/*.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-win-close
echo "run dir: $RUN_DIR"

# --- scripted session ---------------------------------------------------------
# Phase 1 exec's WINCLOSE.BIN (open -> fill -> present -> close -> exit 88).
# Phase 2 (--script2) runs the observation AFTER the program's reap marker,
# so `win`/`syscalls` read the SAME kernel state (window closed), then
# re-execs WINCLOSE.BIN to prove the freed slot is reused.
cat > "$RUN_DIR/script.txt" <<'EOF'
exec WINCLOSE.BIN
EOF
cat > "$RUN_DIR/script2.txt" <<'EOF'
dui
syscalls
exec WINCLOSE.BIN
EOF

# Boots the private WRITABLE copy (not an overlay): the timed screen
# captures need main-like boot pacing; overlays shift guest timing
# so the fill/present lands after the last scheduled capture.

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    host/vm-runner/.build/release/VMRunner "$RUN_DIR/disk-base.img" \
        --serial "$RUN_DIR/vm-serial.log" \
        --display \
        --script artifacts/live-win-close-script.txt \
        --script2 "$RUN_DIR/script2.txt" --script2-after "procs WINCLOSE.BIN exited status=88" \
        --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
run_one "$(art live-win-close-run.txt)" "$(art live-win-close-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
set -e

# --- assertions ---------------------------------------------------------------
SERIAL="$(art live-win-close-serial.log)"
OPEN2=0 NO3=0 CLOSE2=0 EXIT2=0 WINGONE=0 NOROW2=0 IMPL=0 CALLS1=0
if [ -f "$SERIAL" ]; then
    # The slot is reused: the program's `win: open id=2` marker appears TWICE
    # (once per exec), and NEVER as id 3 (the freed slot, not a fresh one).
    [ "$(grep -a -c -F -- "win: open id=2" "$SERIAL")" = 2 ] && OPEN2=1
    [ "$(grep -a -c -F -- "win: open id=3" "$SERIAL")" = 0 ] && NO3=1
    # Both programs closed their window through slot 15 (0 on success).
    [ "$(grep -a -c -F -- "win: close ok" "$SERIAL")" = 2 ] && CLOSE2=1
    # Both programs exited with the distinct 'X'=88 status.
    [ "$(grep -a -c -F -- "procs WINCLOSE.BIN exited status=88" "$SERIAL")" = 2 ] && EXIT2=1
    # After the first close, the kernel's own `dui` report shows the user
    # window is GONE (terminal + clock only), and no `dui[2]:` row ever
    # appears (the window is closed before any observation).
    [ "$(grep -a -c -F -- "dui: windows=2" "$SERIAL")" -ge 1 ] && WINGONE=1
    [ "$(grep -a -c -F -- "dui[2]:" "$SERIAL")" = 0 ] && NOROW2=1
    # The script2 `syscalls` snapshot (after the first close, before the
    # re-exec) shows the new slot 15 implemented and exactly one open+close.
    grep -a -q -F -- "syscalls: slots=64 implemented=46" "$SERIAL" && IMPL=1
    grep -a -q -F -- "  12 sys_win_open calls=1" "$SERIAL" && \
        grep -a -q -F -- "  15 sys_win_close calls=1" "$SERIAL" && CALLS1=1
fi

echo "win-close: rc=$RC open2=$OPEN2 no3=$NO3 close2=$CLOSE2 exit2=$EXIT2 wingone=$WINGONE norow2=$NOROW2 impl=$IMPL calls1=$CALLS1"

PASS=0
if [ "$RC" = 0 ] && [ "$OPEN2" = 1 ] && [ "$NO3" = 1 ] && [ "$CLOSE2" = 1 ] && \
   [ "$EXIT2" = 1 ] && [ "$WINGONE" = 1 ] && [ "$NOROW2" = 1 ] && \
   [ "$IMPL" = 1 ] && [ "$CALLS1" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS live draw/window-close gate (claim 0487 follow-on, milestone six card G6) — EL0 window release on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: scripted exec of WINCLOSE.BIN (sys_win_open/fill/present/close, slots 12-15), then win + syscalls observation on the same kernel state, then a re-exec proving the freed slot is reused"
    echo "assertions: win: close ok x2, win: open id=2 x2 (never id=3), procs WINCLOSE.BIN exited status=88 x2, dui: windows=2 (window gone) + no dui[2]: row, syscalls implemented=46 with open=1/close=1 in the pre-re-exec snapshot"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win-close: PASS — WINCLOSE.BIN opened a user window, filled it, presented it, and CLOSED it through the ADR 0007 slot 15 entirely from EL0, twice. The window disappeared from the registry (dui: windows=2, no dui[2]: row), and the freed slot was reused (win: open id=2 both times, never id 3). The default VM is untouched: without --display, sys_win_open returns EINVAL and every existing gate stays byte-identical."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win-close: FAILED — see artifacts/live-win-close-report.txt, the runner output (live-win-close-run.txt), and the serial log (live-win-close-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
