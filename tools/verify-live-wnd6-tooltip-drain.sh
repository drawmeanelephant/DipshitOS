#!/usr/bin/env bash
#
# verify-live-wnd6-tooltip-drain.sh — M32 WMS6 Gate C (issue #626) class-B gate:
# the tooltip surface drains into WND.BIN.
#
# Gate A drained the keyboard chrome (Alt+Tab), Gate B the click chrome
# (notification center); Gate C activates the read-mostly HOVER chrome — the
# tooltip. The M27 G6 tooltip in the kernel is a DORMANT stub (nothing ever
# calls tooltip_set; M27 G7 was an audit row). While a WM is registered the raw
# hover fanned to the WM (kind 19 WM_POINTER carries absolute moves), the WM
# decides WHEN a tooltip shows and WHAT it says, and issues new slot-65 TOOLTIP
# (cmd 8) with the text via ptr/len. The kernel clamps (32-byte bound), places
# the box below its own cursor, and blits.
#
# Fully CI-runnable with NO Accessibility trust: the hover rides the headless
# --pointer-virtio channel (claim 9367) as a bare MOVE into the tray region
# (1240,700 — the same fb_w-80 slice the WM hit-tests).
#
# Two boots prove both halves:
#   * Boot A (shim regression, no WM): a real hover over the tray changes
#     NOTHING — the kernel's tooltip system is dormant (no phantom box, no
#     fault). Serial proof: `dui tooltip-state: visible=no` + no fault.
#   * Boot B (WM-driven): `wnd start` + a window, then a real hover over the
#     tray. The WM decides and issues TOOLTIP show.
#     Serial proof: the WM's `wnd: tooltip` marker prints, the kernel APPLIED
#     it (`wm: tooltip=[1-9]`), and the box is visible with the WM's text
#     (`dui tooltip-state: visible=yes text=Clock`).
#
# Zero regression: no WM registered -> the dormant shim tooltip stays dormant
# (boot A); the 32-byte bound + box blit are unchanged (WMS8 deletes them).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd6-tooltip-drain.sh
# Evidence: artifacts/live-wnd6-tooltip-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd6-tooltip-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/626

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd6-tooltip-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd6-tooltip-report.txt)"

echo "=== verify-live-wnd6-tooltip-drain: M32 WMS6 Gate C — the tooltip surface drains into WND.BIN (issue #626) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-wnd6-tooltip
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        "$@" \
        > "$(art live-wnd6-tooltip-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd6-tooltip-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# The hover the gate injects — a bare MOVE into the tray region (x in 1200..1280,
# y in 700..720), the same fb_w-80 slice the WM hit-tests for the tooltip.
TRAY_HOVER="1240,700"

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the kernel tooltip system is a dormant stub: a REAL hover
# over the tray changes nothing (no phantom tooltip, no fault). The 20 s dwell
# lets the ring drain before the hover lands.
echo "--- boot A: no WM — a hover changes nothing (the dormant shim, zero regression) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'echo hover-a-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui tooltip-state\necho shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$TRAY_HOVER" --pointer-virtio-after "hover-a-go" \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "hover-a-go" --script3-delay 8 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_VIS_NO=0
A_FAULT=0
SER_A="$(art live-wnd6-tooltip-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The dormant shim shows NOTHING on hover.
    grep -a -qF -- "dui tooltip-state: visible=no" "$SER_A" && A_VIS_NO=1
    # 2) No real fault/panic (exclude the benign `efault` uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_VIS_NO" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven tooltip ---------------------------------------------
# A REAL hover over the tray with WND.BIN registered. The WM receives the
# kind-19 move, hit-tests the tray, decides the tooltip ("Clock"), and issues
# TOOLTIP show with the text via ptr/len. The kernel applies + blits the box
# below its own cursor.
echo "--- boot B: a WM-driven hover shows the tooltip the WM decided (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui\nwm\necho hover-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui tooltip-state\nwm\necho tooltip-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$TRAY_HOVER" --pointer-virtio-after "hover-go" \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "hover-go" --script3-delay 20 \
    --script-expect "tooltip-done" --timeout 260
RC_B=$?
set -e
B_OK=0
WM_TT=0
APPLY=0
VIS_YES=0
TEXT_CLOCK=0
PRESENT=0
SER_B="$(art live-wnd6-tooltip-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided: its `wnd: tooltip` marker printed.
    grep -a -qF -- "wnd: tooltip" "$SER_B" && WM_TT=1
    # 2) The kernel APPLIED the WM's TOOLTIP (cmd-8 counter nonzero in the
    #    `wm` row — the box came from a WM decision, not a kernel self-trigger).
    grep -a -qE -- "tooltip=[1-9][0-9]*" "$SER_B" && APPLY=1
    # 3) The box is visible with the WM's text ("Clock").
    grep -a -qF -- "dui tooltip-state: visible=yes text=Clock" "$SER_B" && VIS_YES=1 && TEXT_CLOCK=1
    # 4) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    if [ "$WM_TT" = 1 ] && [ "$APPLY" = 1 ] && [ "$VIS_YES" = 1 ] && [ "$TEXT_CLOCK" = 1 ] && [ "$PRESENT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS6 Gate C live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  dormant_no_tooltip=$A_VIS_NO  fault=$A_FAULT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven tooltip):"
    echo "  runner rc=$RC_B  wm_tooltip=$WM_TT  applied=$APPLY  visible=$VIS_YES  text_clock=$TEXT_CLOCK  wm_present=$PRESENT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd6-tooltip-drain: PASS — the dormant shim stays dormant on hover (no WM) AND with WND.BIN registered the WM decided the tooltip (the kernel did not)"
    else
        echo "verify-live-wnd6-tooltip-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the dormant shim tooltip state after the hover]" >> "$REPORT"
    grep -a "tooltip-state" "$SER_A" | head -3 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM decision + applied counter + box state]" >> "$REPORT"
    grep -a -E "wnd: (tooltip|present)|wm: .*tooltip=|tooltip-state" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi