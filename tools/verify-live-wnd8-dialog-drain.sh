#!/usr/bin/env bash
#
# verify-live-wnd8-dialog-drain.sh — M32 WMS8 Gates 2+3 (issue #628) class-B
# gate: the keyboard-driven about dialog (Ctrl+Shift+A) drains into WND.BIN
# policy (Gate 2) and the kernel decision is DELETED (Gate 3).
#
# WMS6 left the modal/transient dialogs on the WMS8 backlog ("modal dialogs
# remain on the WMS8 delete-runbook backlog"). Gate 2 (claim 9980) DRAINED the
# about dialog: a new slot-65 DIALOG subcommand (cmd 11) lets the WM decide
# WHEN (it owns the kind-21 keyboard stream), applying the SAME
# `about_dialog_*` primitives the shim's Ctrl+Shift+A chord ran (parity by
# construction). That parity is green with the WM registered, which satisfies
# WMS8's delete rule — so Gate 3 (claim 7736) DELETES the kernel's own
# about-decision: `about_pending`/`take_about()` in input.zig, the shell idle
# block, and the now-dead `about_dialog_hit_test` + pointer close-button path.
# The applied primitives + the modal blit stay (cmd 11 still drives them).
#
# The about dialog is keyboard-driven: Ctrl+Shift+A (HID usage 0x04 + shift).
# When a WM is registered the raw chord fans to the WM (kind 21 WM_KEY with
# MOD_CTRL|MOD_SHIFT), the WM receives usage 0x04 in `handle_wm_key`, and
# issues DIALOG (cmd 11) with a0=2 (toggle). The kernel applies it and blits
# the modal from its own `about_dialog_open` state.
#
# Two boots prove both halves:
#   * Boot A (dormant shim, no WM): NO WM. A REAL Ctrl+Shift+A over the
#     custom-virtio HID keyboard. The kernel's about-decision is DELETED, so
#     the chord does NOTHING in shim mode (the issue's "no compositing policy"
#     end-state) — no `dui: about` line, no fault, shell stays responsive.
#   * Boot B (WM-driven): `wnd start`, then a REAL Ctrl+Shift+A. The WM
#     receives kind 21, decides, and issues DIALOG; the kernel applies it.
#     Serial proof: the WM's `wnd: about` marker AND a nonzero `dialog=` count
#     in the `wm` observability row AND no `dui: about` line (the kernel did
#     not decide — it no longer has the decision).
#
# The `ctrl-shift-a` HID chord token already exists on the headless
# custom-virtio input channel (the generic `ctrl-shift-` map).
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

echo "=== verify-live-wnd8-dialog-drain: M32 WMS8 Gates 2+3 — the about dialog drains into WND.BIN and the kernel decision is deleted (issue #628) ==="

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
gate_seed_share
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

# --- boot A: dormant shim (no WM) ---------------------------------------------
# No WM seated -> the kernel's about-decision is DELETED (Gate 3): a REAL
# Ctrl+Shift+A over the virtio keyboard does NOTHING in shim mode (the issue's
# "no compositing policy" end-state) — no `dui: about` line, no fault, and the
# shell stays responsive (script-expect proves the boot is healthy).
echo "--- boot A: no WM — the dormant shim does nothing on Ctrl+Shift+A (kernel decision deleted) ---"
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
DORMANT=0
SER_A="$(art live-wnd8-dialog-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # The kernel's about-decision is DELETED: the shell never prints `dui:
    # about` (no self-toggle at all). The chord must be a no-op — count 0 —
    # and the boot must be healthy (rc=0 already implies script-expect met).
    DORMANT=0
    grep -a -qF -- "dui: about" "$SER_A" && DORMANT=1
    if [ "$DORMANT" = 0 ]; then
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
    echo "--- WMS8 Gates 2+3 live report ---"
    echo "boot A (dormant shim, no WM):"
    echo "  runner rc=$RC_A  dui_about_count=$DORMANT (must be 0)"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven about dialog):"
    echo "  runner rc=$RC_B  wm_about=$WM_ABOUT  kernel_about=$KERNEL_ABOUT  key_fan=$KEYFAN  wm_present=$PRESENT  applied=$APPLY"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd8-dialog-drain: PASS — with no WM the dormant shim does nothing on Ctrl+Shift+A (kernel decision deleted) AND with WND.BIN registered the WM decided Ctrl+Shift+A and the kernel applied it"
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