#!/usr/bin/env bash
#
# verify-live-wnd6-dock-drain.sh — M32 WMS6 Gate D (issue #626) class-B gate:
# the dock drains into WND.BIN.
#
# Gates A/B/C drained the keyboard, click, and hover chrome. Gate D drains the
# dock (M15 C4): the 24 px left icon bar. While a WM is registered the raw dock
# click fans to the WM (kind 19 with the button byte); the WM hit-tests the
# icon grid (the shim's 20×20 boxes at (2, 8+idx*32)), decides which icon, and
# issues new slot-65 DOCK (cmd 9) — the kernel applies the SAME clamped chain
# the shim runs (restore-first-minimized -> focus/raise -> open). Hover labels
# ride the Gate-C TOOLTIP seam (the WM issues the icon's label over cmd 8).
#
# Fully CI-runnable with NO Accessibility trust: clicks + hovers ride the
# headless --pointer-virtio channel (claim 9367).
#
# Two boots prove both halves:
#   * Boot A (shim regression, no WM): minimize NOTEPAD (`dui minimize 2`),
#     then a REAL click on dock icon 0 (12,18). The shim's dock-click handler
#     restores it (focused=2, visible). Zero regression.
#   * Boot B (WM-driven): `wnd start` + NOTEPAD, minimize it, then a REAL
#     hover on icon 0 (12,24) + click on icon 0 (12,18). The kernel must NOT
#     self-handle the click (its dock handler is gated); the WM decides.
#     Serial proof: `wnd: dock idx=0` (WM decided), `wm: dock=[1-9]` (kernel
#     applied), NOTEPAD restored (`focused=2`), AND the hover label rode the
#     Gate-C seam (`wnd: tooltip` + `dui tooltip-state: visible=yes text=Calc`).
#
# Zero regression: no WM registered -> the shim dock-click path is
# byte-identical (boot A); the bar blit + icon glyphs + restore chain unchanged.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd6-dock-drain.sh
# Evidence: artifacts/live-wnd6-dock-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd6-dock-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/626

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd6-dock-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd6-dock-report.txt)"

echo "=== verify-live-wnd6-dock-drain: M32 WMS6 Gate D — the dock drains into WND.BIN (issue #626) ==="

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
gate_begin live-wnd6-dock
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
        > "$(art live-wnd6-dock-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd6-dock-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# Dock icon 0 (the bar's first 20×20 box at (2, 8..28)): a hover at its middle
# (12,24) and a click at its center (12,18) — inside the shim's hit box.
DOCK_HOVER="12,24"
DOCK_CLICK="12,18,c"

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the shell idle shim still owns the dock: a REAL click on icon
# 0 restores the minimized NOTEPAD (focused=2). The 20 s dwell lets the ring
# drain before the click lands.
echo "--- boot A: no WM — a dock click still restores the minimized window (zero regression) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui minimize 2\ndui\necho dock-a-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\necho shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$DOCK_CLICK" --pointer-virtio-after "dock-a-go" \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "dock-a-go" --script3-delay 8 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_MIN=0
A_FOCUS=0
A_FAULT=0
SER_A="$(art live-wnd6-dock-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The minimize happened (the shim's pre-click state).
    grep -a -qF -- "dui minimize: minimized id=2" "$SER_A" && A_MIN=1
    # 2) The dock click restored + focused NOTEPAD (the post-click dui header).
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_A" && A_FOCUS=1
    # 3) No real fault/panic (exclude the benign `efault` uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_MIN" = 1 ] && [ "$A_FOCUS" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven dock ------------------------------------------------
# A REAL hover on icon 0 (label via the Gate-C TOOLTIP seam) + a REAL click on
# icon 0 with WND.BIN registered. The kernel must NOT self-handle the click
# (its dock handler is gated behind !wm_owns_input); the WM receives kind 19,
# hit-tests the icon grid, decides, and issues DOCK.
echo "--- boot B: a WM-driven dock click restores the window the WM decided (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui minimize 2\ndui\nwm\necho dock-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\ndui tooltip-state\nwm\necho dock-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$DOCK_HOVER;$DOCK_CLICK" --pointer-virtio-after "dock-go" \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "dock-go" --script3-delay 20 \
    --script-expect "dock-done" --timeout 260
RC_B=$?
set -e
B_OK=0
WM_DOCK=0
APPLY=0
RESTORED=0
TT_LABEL=0
TT_TEXT=0
PRESENT=0
SER_B="$(art live-wnd6-dock-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided the click: its `wnd: dock idx=0` marker printed.
    grep -a -qF -- "wnd: dock idx=0" "$SER_B" && WM_DOCK=1
    # 2) The kernel APPLIED the WM's DOCK (cmd-9 counter nonzero in the `wm`
    #    row — the restore came from a WM decision, not a kernel self-click).
    grep -a -qE -- "dock=[1-9][0-9]*" "$SER_B" && APPLY=1
    # 3) NOTEPAD was restored + focused (the post-click dui header).
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_B" && RESTORED=1
    # 4) The hover label rode the Gate-C TOOLTIP seam: `wnd: tooltip` printed
    #    AND the box shows the icon's label.
    grep -a -qF -- "wnd: tooltip" "$SER_B" && TT_LABEL=1
    grep -a -qF -- "dui tooltip-state: visible=yes text=Calc" "$SER_B" && TT_TEXT=1
    # 5) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    if [ "$WM_DOCK" = 1 ] && [ "$APPLY" = 1 ] && [ "$RESTORED" = 1 ] && [ "$TT_LABEL" = 1 ] && [ "$TT_TEXT" = 1 ] && [ "$PRESENT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS6 Gate D live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  minimized=$A_MIN  restored_focused=$A_FOCUS  fault=$A_FAULT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven dock):"
    echo "  runner rc=$RC_B  wm_dock=$WM_DOCK  applied=$APPLY  restored=$RESTORED  hover_label=$TT_LABEL  label_text=$TT_TEXT  wm_present=$PRESENT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd6-dock-drain: PASS — the shim dock-click still restores (no WM) AND with WND.BIN registered the WM decided the dock click + hover label (the kernel did not)"
    else
        echo "verify-live-wnd6-dock-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the shim minimize + post-click restore]" >> "$REPORT"
    grep -a -E "dui minimize|dui: windows=" "$SER_A" | head -4 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM decision + applied counter + label]" >> "$REPORT"
    grep -a -E "wnd: (dock|tooltip|present)|wm: .*dock=|dui: windows=|tooltip-state" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi