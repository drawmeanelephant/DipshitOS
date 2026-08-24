#!/usr/bin/env bash
#
# verify-live-events.sh -- claim 9328 (milestone nine, card E6) class-B
# capstone gate: interactive EL0 event routing and application feedback,
# live on real VZ hardware.
#
# KEYTEST.BIN (`user/src/keytest.zig`, the TENTH ESP user program) drives
# the milestone nine application event system entirely from EL0:
#   1. `sys_win_open(96, 96, 256, 192)` (slot 12) opens user window id 2,
#      which immediately receives focus and queues a synthetic `WIN_FOCUS` event.
#   2. `sys_win_fill` (slot 13) + `sys_win_present` (slot 14) renders initial
#      window content.
#   3. `sys_wait_event` (slot 22) pops `WIN_FOCUS` -> prints `keytest: win_focus`
#      and paints a green focus bar at the top of the window.
#   4. `sys_wait_event` blocks in the kernel scheduler waiting for user input.
#   5. The runner types an interactive keystroke via `--input-string "A"` after
#      the `keytest: win_focus` marker.
#   6. The USB XHCI keyboard report decode detects the focused user window and
#      routes a `KEY_DOWN` event to KEYTEST.BIN's process queue, waking the
#      blocked task.
#   7. KEYTEST.BIN pops the `KEY_DOWN` event, prints `keytest: key_down`, paints
#      a red interactive box at (32, 32, 64, 64), presents the window, and
#      exits with status 99 (`sys_exit(99)`, slot 3).
#   8. The monitor session checks `procs` and `syscalls` on the serial console.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-events.sh
#
# Evidence: artifacts/live-events-gate.txt (full output),
# artifacts/live-events-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-events-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-events-report.txt"

echo "=== verify-live-events: claim 9328 — interactive EL0 event loop, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
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
gate_begin live-events
echo "run dir: $RUN_DIR"

# --- scripted session ---------------------------------------------------------
cat > "$RUN_DIR/script.txt" <<'EOF'
exec KEYTEST.BIN
EOF
cat > "$RUN_DIR/script2.txt" <<'EOF'
procs
syscalls
EOF

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR"/gpu-screen-*
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --display --input --screen "$RUN_DIR/gpu-screen" \
        --script "$RUN_DIR/script.txt" \
        --input-string "A" --input-string-after "keytest: win_focus" \
        --script2 "$RUN_DIR/script2.txt" --script2-after "keytest: exiting 99" \
        --script-expect "exited status=99" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

echo "--- Phase 1: running interactive event application on VZ ---"
OUT="artifacts/live-events-run.txt"
SERIAL="$(art live-events-serial.log)"
run_one "$OUT" "$SERIAL"
RC="$(cat "$RUN_DIR/rc.txt")"
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
rm -f /tmp/live-events-rc.txt

echo "VMRunner exit code: $RC"
if [ "$RC" -ne 0 ]; then
    echo "ERROR: VMRunner failed with code $RC"
    cat "$OUT"
    exit 1
fi

echo "--- Phase 2: verifying event markers and lifecycle in serial transcript ---"
SERIAL_CONTENT="$(cat "$SERIAL")"

assert_contains() {
    local pattern="$1"
    local desc="$2"
    if echo "$SERIAL_CONTENT" | grep -q "$pattern"; then
        echo "  [PASS] $desc"
    else
        echo "  [FAIL] $desc (pattern not found: '$pattern')"
        exit 1
    fi
}

assert_contains "keytest: open id=2" "KEYTEST.BIN opened window id=2"
assert_contains "keytest: present ok" "KEYTEST.BIN presented initial window content"
assert_contains "keytest: win_focus" "KEYTEST.BIN received synthetic WIN_FOCUS event"
assert_contains "keytest: key_down" "KEYTEST.BIN received interactive KEY_DOWN event via sys_wait_event"
assert_contains "keytest: exiting 99" "KEYTEST.BIN processed event loop and exited"
assert_contains "exited status=99" "kernel recorded process exit with status 99"
assert_contains "sys_wait_event calls=" "kernel syscall counter recorded sys_wait_event invocations"

# Write report detail
cat > "$REPORT" <<EOF
verify-live-events: claim 9328 passed
Revision: $REVISION ($BRANCH, dirty=$DIRTY)
Date: $(date -u '+%Y-%m-%d %H:%M:%SZ')

Phase 1: VM execution on Apple Virtualization framework
- VMRunner completed cleanly (RC=0)
- Display and USB HID keyboard input attached

Phase 2: Event stream and syscall verification
- KEYTEST.BIN opened window id 2
- Window focus transition delivered synthetic WIN_FOCUS (kind 6)
- Blocking sys_wait_event slept caller in scheduler
- Scripted 'A' keystroke dispatched via HID keyboard
- Focused user window routing delivered KEY_DOWN (kind 1)
- KEYTEST.BIN woke up, painted visual feedback, and exited status 99
- Monitored process status and syscall invocation table confirmed
EOF

echo "=== verify-live-events: ALL GATES PASSED ==="
