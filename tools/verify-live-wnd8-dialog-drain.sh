#!/usr/bin/env bash
#
# verify-live-wnd8-dialog-drain.sh — M32 WMS8 Gate 2 (issue #628) class-B gate:
# the keyboard-driven about dialog (Ctrl+Shift+A) drains into WND.BIN policy.
#
# WMS6 left the modal/transient dialogs on the WMS8 backlog ("modal dialogs
# remain on the WMS8 delete-runbook backlog"). Unlike Gate 1 (the tooltip
# dwell — provably dead with zero callers), the about dialog is still the
# shim's ONLY implementation, reachable in default no-WM boots, which WMS8
# forbids deleting. So this gate is a DRAIN (not a deletion): it gives the WM
# dialog ownership via a new slot-65 DIALOG subcommand (cmd 11), gates the
# kernel's own Ctrl+Shift+A self-toggle behind !wm_owns_input (input.zig),
# keeps the shim copy byte-identical, and proves parity live. The DELETION of
# the now-dormant kernel decision is a later WMS8 gate.
#
# The about dialog is keyboard-driven: Ctrl+Shift+A (HID usage 0x04 + shift).
# When a WM is registered the raw chord fans to the WM (kind 21 WM_KEY with
# MOD_CTRL|MOD_SHIFT), the WM receives usage 0x04 in `handle_wm_key`, and
# issues DIALOG (cmd 11) with a0=2 (toggle) — the SAME kernel primitive the
# shim's Ctrl+Shift+A chord runs (parity by construction). The kernel applies
# it and blits the modal from its own `about_dialog_open` state.
#
# Two boots prove both halves:
#   * Boot A (shim regression): NO WM. A REAL Ctrl+Shift+A over the
#     custom-virtio HID keyboard. The shell idle's shim path self-toggles the
#     about dialog as before (zero regression).
#     Serial proof: `dui: about=open` prints.
#   * Boot B (WM-driven): `wnd start`, then a REAL Ctrl+Shift+A. The kernel
#     must NOT consume it (no `dui: about` — the pending flag is gated behind
#     !wm_owns_input); the WM receives kind 21, decides, and issues DIALOG.
#     Serial proof: the WM's `wnd: about` marker AND a nonzero `dialog=` count
#     in the `wm` observability row AND no `dui: about` line (the kernel did
#     not decide).
#
# Zero regression: no WM registered -> the shim Ctrl+Shift+A path is
# byte-identical (boot A). The `ctrl-shift-a` HID chord token already exists
# on the headless custom-virtio input channel (the generic `ctrl-shift-` map).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd8-dialog-drain.sh
# Evidence: artifacts/live-wnd8-dialog-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd8-dialog-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/628

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd8-dialog-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd8-dialog-report.txt)"

echo "=== verify-live-wnd8-dialog-drain: M32 WMS8 Gate 2 — the about dialog drains into WND.BIN (issue #628) ==="

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
gate_begin live-wnd8-dialog
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
        > "$(art live-wnd8-dialog-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd8-dialog-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the shell idle shim still owns Ctrl+Shift+A: a REAL chord
# over the virtio keyboard self-toggles the about dialog (zero regression).
echo "--- boot A: no WM — the shim still self-toggles the about dialog (zero regression) ---"
printf 'echo bootA-go\n' > "$RUN_DIR/script-A.txt"
printf 'echo shim-go\n' > "$RUN_DIR/s2-A.txt"
printf 'echo shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "bootA-go" --script2-delay 6 \
    --input-chords "ctrl-shift-a" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "shim-go" --script3-delay 8 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
SHIM=0
SER_A="$(art live-wnd8-dialog-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # The shim opened the about dialog from the real Ctrl+Shift+A (the `dui:
    # about=open` line prints from the shell idle — proof the chord worked).
    SHIM=0
    grep -a -qF -- "dui: about=open" "$SER_A" && SHIM=1
    if [ "$SHIM" = 1 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven about dialog ---------------------------------------
# A REAL Ctrl+Shift+A over the virtio keyboard with WND.BIN registered. The
# kernel must NOT consume it (its pending flag is gated behind wm_owns_input);
# the WM receives kind 21 (usage 0x04 + shift), decides, and issues DIALOG.
echo "--- boot B: a WM-driven Ctrl+Shift+A opens the about dialog (the kernel does not decide) ---"
printf 'wnd start\nexec M21DEMO.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'wm\necho chord-go\n' > "$RUN_DIR/s2-B.txt"
printf 'wm\necho about-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "m21demo: loop ok" --script2-delay 10 \
    --input-chords "ctrl-shift-a" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chord-go" --script3-delay 14 \
    --script-expect "about-done" --timeout 260
RC_B=$?
set -e
B_OK=0
WM_ABOUT=0; KERNEL_ABOUT=0; KEYFAN=0; PRESENT=0; APPLY=0
SER_B="$(art live-wnd8-dialog-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided: its `wnd: about` marker printed.
    WM_ABOUT=0
    grep -a -qF -- "wnd: about" "$SER_B" && WM_ABOUT=1
    # 2) The kernel did NOT consume the chord (no `dui: about` from the
    #    keyboard path — the pending flag is gated behind !wm_owns_input).
    KERNEL_ABOUT=0
    grep -a -qF -- "dui: about" "$SER_B" && KERNEL_ABOUT=1
    # 3) The keyboard seam fanned the key out (kind 21) AND the WM stayed
    #    seated + pacing.
    KEYFAN=0; PRESENT=0
    grep -a -qE -- "key_fan=[1-9][0-9]*" "$SER_B" && KEYFAN=1
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    # 4) The kernel applied the WM's DIALOG (the cmd-11 counter is nonzero in
    #    the `wm` observability row — an applied decision, not a dropped one).
    APPLY=0
    grep -a -qE -- "dialog=[1-9][0-9]*" "$SER_B" && APPLY=1
    if [ "$WM_ABOUT" = 1 ] && [ "$KERNEL_ABOUT" = 0 ] && [ "$KEYFAN" = 1 ] && [ "$PRESENT" = 1 ] && [ "$APPLY" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS8 Gate 2 live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  about_shim=$SHIM"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven about dialog):"
    echo "  runner rc=$RC_B  wm_about=$WM_ABOUT  kernel_about=$KERNEL_ABOUT  key_fan=$KEYFAN  wm_present=$PRESENT  applied=$APPLY"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd8-dialog-drain: PASS — the shim still self-toggles the about dialog (no WM) AND with WND.BIN registered the WM decided Ctrl+Shift+A (the kernel did not)"
    else
        echo "verify-live-wnd8-dialog-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: shim about-dialog rows]" >> "$REPORT"
    grep -a "dui: about" "$SER_A" | head -4 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM's about decision + counters]" >> "$REPORT"
    grep -a -E "wnd: (about|present)|wm: (key_fan|dialog)|dui: about" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi