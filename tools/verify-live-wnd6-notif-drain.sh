#!/usr/bin/env bash
#
# verify-live-wnd6-notif-drain.sh — M32 WMS6 Gate B (issue #626) class-B gate:
# the notification center drains into WND.BIN.
#
# Gate A (alt-tab) drained the keyboard-driven chrome; Gate B drains the
# flagship click-driven surface. While a WM is registered the raw pointer click
# on the TRAY fans to the WM (kind 19 WM_POINTER carries the HID button byte);
# the WM hit-tests the tray (the same fb_w-80 slice as the kernel tray_rect),
# decides open/close, and issues new slot-65 NOTIF_CENTER (cmd 6). The kernel's
# OWN tray-click toggle + panel dismiss/clear are gated behind !wm_owns_input.
#
# Fully CI-runnable with NO Accessibility trust: the click rides the headless
# --pointer-virtio channel (claim 9367 — custom-virtio kind-2 absolute pointer).
# The injected click (1240,710) is inside BOTH the kernel tray_rect and the
# WM's tray region, so it drives the shim (boot A) and the WM (boot B).
#
# Two boots prove both halves:
#   * Boot A (shim regression, no WM): inject a real tray click. The shim's
#     click path toggles the panel open (`dui notif-center-state: open=yes`)
#     — zero regression. Serial proof: the click opened the panel + no fault.
#   * Boot B (WM-driven): `wnd start` + a window, then inject a real tray
#     click. The kernel must NOT self-toggle (its tray-click path is gated);
#     the WM receives kind 19, decides, and issues NOTIF_CENTER.
#     Serial proof: the WM's `wnd: notif-open` marker prints, the kernel
#     APPLIED it (`wm: notif=[1-9]`), and the panel is open (`dui
#     notif-center-state: open=yes`).
#
# Zero regression: no WM registered -> the shim click path is byte-identical
# (boot A); the notification panel blit/logic is unchanged (the M21 W5 rows).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd6-notif-drain.sh
# Evidence: artifacts/live-wnd6-notif-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd6-notif-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/626

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd6-notif-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd6-notif-report.txt)"

echo "=== verify-live-wnd6-notif-drain: M32 WMS6 Gate B — notification center drains into WND.BIN (issue #626) ==="

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
gate_begin live-wnd6-notif
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
        > "$(art live-wnd6-notif-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd6-notif-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# The tray click the gate injects — inside BOTH the kernel tray_rect
# (x in 1200..1280, y in 700..720) and the WM's fb_w-80 tray region.
TRAY_CLICK="1240,710,c"

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the shell idle shim still owns the notification center: a REAL
# tray click over the virtio pointer opens the panel. The 20 s dwell lets the
# ring drain before the click lands.
echo "--- boot A: no WM — the shim still opens the panel on a tray click (zero regression) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'echo click-a-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui notif-center-state\necho shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$TRAY_CLICK" --pointer-virtio-after "click-a-go" \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "click-a-go" --script3-delay 8 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_OPEN=0
A_FAULT=0
SER_A="$(art live-wnd6-notif-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The shim toggled the panel OPEN on the injected tray click.
    grep -a -qF -- "dui notif-center-state: open=yes" "$SER_A" && A_OPEN=1
    # 2) No real fault/panic during the run (exclude the benign `efault`
    #    uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_OPEN" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven notification center ---------------------------------
# A REAL tray click with WND.BIN registered. The kernel must NOT self-toggle
# (its tray-click path is gated behind !wm_owns_input); the WM receives kind
# 19, hit-tests the tray, decides, and issues NOTIF_CENTER (cmd 6). The 20 s
# dwell lets the WM seat + park in sys_wait_event before the click lands.
echo "--- boot B: a WM-driven tray click opens the panel (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui\nwm\necho chord-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui notif-center-state\nwm\necho notif-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "$TRAY_CLICK" --pointer-virtio-after "chord-go" \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chord-go" --script3-delay 20 \
    --script-expect "notif-done" --timeout 260
RC_B=$?
set -e
B_OK=0
WM_NOTIF=0
APPLY=0
OPEN_B=0
PRESENT=0
SER_B="$(art live-wnd6-notif-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided: its `wnd: notif-open` marker printed.
    grep -a -qF -- "wnd: notif-open" "$SER_B" && WM_NOTIF=1
    # 2) The kernel APPLIED the WM's NOTIF_CENTER (cmd-6 counter nonzero in the
    #    `wm` row — the panel opened via a WM decision, not a kernel self-toggle).
    grep -a -qE -- "notif=[1-9][0-9]*" "$SER_B" && APPLY=1
    # 3) The panel is actually OPEN after the click.
    grep -a -qF -- "dui notif-center-state: open=yes" "$SER_B" && OPEN_B=1
    # 4) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    if [ "$WM_NOTIF" = 1 ] && [ "$APPLY" = 1 ] && [ "$OPEN_B" = 1 ] && [ "$PRESENT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS6 Gate B live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  panel_open=$A_OPEN  fault=$A_FAULT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven notification center):"
    echo "  runner rc=$RC_B  wm_notif=$WM_NOTIF  applied=$APPLY  panel_open=$OPEN_B  wm_present=$PRESENT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd6-notif-drain: PASS — the shim still opens the panel on a tray click (no WM) AND with WND.BIN registered the WM decided open/close (the kernel did not)"
    else
        echo "verify-live-wnd6-notif-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the shim panel state after the tray click]" >> "$REPORT"
    grep -a "notif-center-state" "$SER_A" | head -3 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM decision + applied counter + panel state]" >> "$REPORT"
    grep -a -E "wnd: (notif|present)|wm: .*notif=|notif-center-state" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi