#!/usr/bin/env bash
#
# verify-live-wnd-server.sh -- M32 WMS3 (issue #623) class-B gate: the
# long-lived EL0 WM server (WND.BIN) end to end on real VZ hardware.
#
# ONE headless boot with --screen only (GPU attached so the compositor is
# armed — the REGISTER ENXIO gate; no --display, no --input). THREE scripted
# phases (the claim-4613 machinery), because `exec` is asynchronous and the
# server paces on 1 Hz scheduler ticks:
#
#   Phase 1 (--script, forwarded at boot):
#   1. `wm`         -> "wm: none (shim compositing)"   [shim mode, default]
#   2. `wnd start`  -> execs WND.BIN (the bootstrap). The server:
#        a. sys_wmctl(REGISTER) (slot 65, cmd 1) -> 0    "wnd: registered"
#        b. loops on sys_wait_event (slot 22) servicing kind-18
#           COMPOSITE_TICK; every 2 ticks it issues REQUEST_PRESENT
#           (slot 65, cmd 3) — the FIRST present pacing that is not the
#           shell idle (the shell idle drain is gated off while a WM is
#           registered, WMS2).                                "wnd: present"
#      The first "wnd: present" marker is the phase-2 trigger — pacing is
#      proven before the crash story starts.
#
#   Phase 2 (--script2, after the first present marker):
#   3. `wm`         -> "wm: registered pid=N present_seq=P presents=M
#                      ticks=T" with P >= 1 (the server's own pacing
#                      advanced the present-sequence while the shell idle
#                      was idle)
#   4. `wnd`        -> the same report through the wnd command
#   5. `kill WND.BIN` -> the crash story starts: the kernel's WMS2 exit-path
#      teardown unregisters the WM and the shell idle drains
#      "wm: unregistered, shim resumed"; the task reaps.
#
#   Phase 3 (--script3, after the reap line):
#   6. `wm`         -> "wm: none (shim compositing)"     [fallback resumed]
#   7. `wnd start`  -> a FRESH WND.BIN re-registers into the freed seat
#                      (second "wnd: registered")
#   8. `echo rx-wnd-server-ok` -> shell responsive (this is the
#      --script-expect; the runner stops the VM on it).
#
# Zero-regression: the default VM never runs `wnd start` (WND.BIN is not in
# APPS.TXT), so the shim keeps compositing exactly as before and every
# pre-M32 gate is untouched.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m32-wms3-wnd-server-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-wnd-server-report.txt)"
EXEC_REAP_LINE="tasks user-exec reaped"
EXEC_KILL_LINE="tasks user-exec exited status=137"

echo "=== verify-live-wnd-server: M32 WMS3 — long-lived EL0 WM server (issue #623), $BOOTS boot(s) ==="

zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
gate_begin live-wnd-server
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
SCRIPT2="$RUN_DIR/script2.txt"
SCRIPT3="$RUN_DIR/script3.txt"

# Phase 1: shim mode, then launch the server and let it pace.
printf 'wm\nwnd start\n' > "$SCRIPT"
# Phase 2: snapshot the seated server, then crash it.
printf 'wm\nwnd\nkill WND.BIN\n' > "$SCRIPT2"
# Phase 3: fallback confirmed, then re-register from a fresh server.
printf 'wm\nwnd start\necho rx-wnd-server-ok\n' > "$SCRIPT3"

run_one() {
    local tag="$1"
    local run_log="$(art live-wnd-server-run-$tag.txt)"
    local serial_copy="$(art live-wnd-server-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --script "$SCRIPT" \
        --script2 "$SCRIPT2" --script2-after "wnd: present" \
        --script3 "$SCRIPT3" --script3-after "$EXEC_REAP_LINE" \
        --script-expect "rx-wnd-server-ok" --timeout 120 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 shim=0 registered2=0 present=0 wm_registered=0 \
        pseq_ge1=0 killed=0 reaped=0 fallback=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "wm: none (shim compositing)" "$SER" || true)" -ge 2 ] && shim=1
        # Two server instances total (phase 1 + phase 3 re-register).
        [ "$(grep -aFc -- "wnd: registered" "$SER" || true)" -ge 2 ] && registered2=1
        # The server paced on its own (phase-1 trigger marker).
        [ "$(grep -aFc -- "wnd: present" "$SER" || true)" -ge 1 ] && present=1
        # The phase-2 snapshot shows the seated server.
        [ "$(grep -aFc -- "wm: registered pid=" "$SER" || true)" -ge 1 ] && wm_registered=1
        # ... and its own pacing advanced the present sequence (>= 1).
        local pseq=0
        pseq="$(grep -aom1 -- 'wm: present_seq=[0-9]\+' "$SER" | head -1 | grep -ao '[0-9]\+' || true)"
        if [ -n "$pseq" ] && [ "$pseq" -ge 1 ]; then pseq_ge1=1; fi
        # The crash story: kill -> teardown -> reap.
        [ "$(grep -aFc -- "$EXEC_KILL_LINE" "$SER" || true)" -ge 1 ] && killed=1
        [ "$(grep -aFc -- "$EXEC_REAP_LINE" "$SER" || true)" -ge 1 ] && reaped=1
        # The kernel's WMS2 teardown fallback report.
        [ "$(grep -aFc -- "wm: unregistered, shim resumed" "$SER" || true)" -ge 1 ] && fallback=1
        [ "$(grep -aFc -- "rx-wnd-server-ok" "$SER" || true)" -ge 1 ] && echo_ok=1
        if [ "$(grep -aFc -- "\[EXC\]" "$SER" || true)" = 0 ] && [ "$(grep -aFc -- "kernel panic" "$SER" || true)" = 0 ]; then
            fatal=0
        else
            fatal=1
        fi
    fi

    {
        echo "run $tag: rc=$rc bytes=$bytes"
        echo "  banner=$banner shim-before+after=$shim registered-x2=$registered2 present=$present wm-registered=$wm_registered present-seq>=1=$pseq_ge1 killed=$killed reaped=$reaped fallback=$fallback echo-ok=$echo_ok fatal=$fatal"
    } | tee -a "$REPORT"

    [ "$rc" = 0 ] || { echo "FAIL: runner exit $rc (log: $run_log)"; return 1; }
    [ "$banner" = 1 ] || { echo "FAIL: kernel banner missing"; return 1; }
    [ "$shim" = 1 ] || { echo "FAIL: shim mode ('wm: none') not observed before AND after the server"; return 1; }
    [ "$registered2" = 1 ] || { echo "FAIL: expected TWO 'wnd: registered' (phase 1 + phase 3 re-register)"; return 1; }
    [ "$present" = 1 ] || { echo "FAIL: WND.BIN never paced ('wnd: present' missing)"; return 1; }
    [ "$wm_registered" = 1 ] || { echo "FAIL: phase-2 'wm' did not show the registered pid"; return 1; }
    [ "$pseq_ge1" = 1 ] || { echo "FAIL: present-sequence did not advance (WM pacing off the shell idle)"; return 1; }
    [ "$killed" = 1 ] || { echo "FAIL: WND.BIN was not killed (status 137)"; return 1; }
    [ "$reaped" = 1 ] || { echo "FAIL: WND.BIN not reaped (phase-3 trigger)"; return 1; }
    [ "$fallback" = 1 ] || { echo "FAIL: no 'wm: unregistered, shim resumed' fallback report"; return 1; }
    [ "$echo_ok" = 1 ] || { echo "FAIL: shell did not echo rx-wnd-server-ok after the lifecycle"; return 1; }
    [ "$fatal" = 0 ] || { echo "FAIL: kernel fault/panic observed"; return 1; }
    return 0
}

pass=0
for i in $(seq 1 "$BOOTS"); do
    echo "--- boot $i/$BOOTS ---"
    if run_one "$i"; then
        pass=$((pass + 1))
        echo "boot $i: PASS"
    else
        echo "boot $i: FAIL"
    fi
done
gate_end

if [ "$pass" -ne "$BOOTS" ]; then
    echo "verify-live-wnd-server: FAIL — $pass/$BOOTS boots passed (see $GATE_LOG)"
    exit 1
fi

echo "verify-live-wnd-server: PASS — WND.BIN booted via 'wnd start', REGISTERed (slot 65), serviced kind-18 COMPOSITE_TICKs and REQUEST_PRESENTed at its own cadence (present-sequence advanced while the shell idle was idle); kill WND.BIN triggered the WMS2 exit-path teardown + shim fallback; a fresh 'wnd start' re-registered into the freed seat; the shell stayed responsive. Default VM (no 'wnd start') is untouched — the shim path reads unchanged."
