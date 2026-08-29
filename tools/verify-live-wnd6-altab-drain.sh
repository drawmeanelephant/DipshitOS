#!/usr/bin/env bash
#
# verify-live-wnd6-altab-drain.sh — M32 WMS6 Gate A (issue #626) class-B gate:
# Alt+Tab policy drains into WND.BIN.
#
# The first desktop-chrome surface to leave the kernel (the issue's "read-mostly,
# keyboard-driven first" guidance) is Alt+Tab: which window the chord switches to.
# When a WM is registered the raw Alt+Tab chord fans to the WM (kind 21 WM_KEY
# with MOD_ALT), the WM computes the target from its kind-20 mirror registry via
# the shared wnd_core rules, and issues a new slot-65 ALT_TAB subcommand (cmd 5)
# — the kernel clamps + repaints the overlay blit from the WM's choice. The
# kernel's own Alt+Tab self-cycle is gated off (like the other keyboard
# geometry consumers) while a WM is registered.
#
# Two boots prove both halves:
#   * Boot A (shim regression): NO WM. `exec M21DEMO.BIN` (two user windows),
#     then a REAL Alt+Tab over the custom-virtio HID keyboard. The shell idle's
#     shim path self-cycles the overlay as before (zero regression).
#     Serial proof: `dui: alt-tab active count=` prints.
#   * Boot B (WM-driven): `wnd start` + `exec M21DEMO.BIN`, then a REAL Alt+Tab.
#     The kernel must NOT consume it (no `dui: alt-tab` — the pending flag is
#     gated behind !wm_owns_input); the WM receives kind 21, decides the target
#     via its mirrors, and issues ALT_TAB commit.
#     Serial proof: the WM's `wnd: alt-tab id=` marker prints AND no `dui:
#     alt-tab` line appears (the kernel did not decide).
#
# Zero regression: no WM registered -> the shim Ctrl path is byte-identical
# (boot A). This gate also introduces the `alt-tab` HID chord token (LAlt +
# Tab usage 0x2B) to the headless custom-virtio input channel.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd6-altab-drain.sh
# Evidence: artifacts/live-wnd6-altab-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd6-altab-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/626

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd6-altab-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd6-altab-report.txt)"

echo "=== verify-live-wnd6-altab-drain: M32 WMS6 Gate A — Alt+Tab policy drains into WND.BIN (issue #626) ==="

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
gate_begin live-wnd6-altab
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
        > "$(art live-wnd6-altab-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd6-altab-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the shell idle shim still owns Alt+Tab: a REAL Alt+Tab over
# the virtio keyboard opens the overlay + cycles focus (zero regression). The
# 20 s settled dwell before the chord lets the two M21DEMO windows open and the
# ring drain, then the chord lands on a live shell.
echo "--- boot A: no WM — the shim still self-cycles Alt+Tab (zero regression) ---"
printf 'exec M21DEMO.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'echo shim-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\necho shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "alt-tab" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "shim-go" --script3-delay 8 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
ALT=0
WIN2=0
SER_A="$(art live-wnd6-altab-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The shim opened + cycled the Alt+Tab overlay (the M15 C2 path printed
    #    from the shell idle — proof Alt+Tab still works with no WM).
    ALT=0
    grep -a -qE -- "dui: alt-tab (active|cycle)" "$SER_A" && ALT=1
    # 2) The two M21DEMO windows opened (>= 2 user windows is what made the
    #    overlay able to activate).
    WIN2=0
    grep -a -qF -- "exec ok" "$SER_A" && WIN2=1
    if [ "$ALT" = 1 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven Alt+Tab -------------------------------------------
# A REAL Alt+Tab over the virtio keyboard with WND.BIN registered. The kernel
# must NOT consume it (its pending flag is gated behind !wm_owns_input); the WM
# receives kind 21 (MOD_ALT), decides the target from its kind-20 mirrors, and
# issues ALT_TAB commit. The 20 s dwell lets the mirrors accumulate (the ring
# rotates on 1 Hz timer ticks), then the chord lands while the WM is parked in
# sys_wait_event.
echo "--- boot B: a WM-driven Alt+Tab switches to the WM's chosen window (the kernel does not decide) ---"
printf 'wnd start\nexec M21DEMO.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui\nwm\necho chord-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\nwm\necho alt-tab-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "alt-tab" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chord-go" --script3-delay 20 \
    --script-expect "alt-tab-done" --timeout 260
RC_B=$?
set -e
B_OK=0
SER_B="$(art live-wnd6-altab-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided: its `wnd: alt-tab id=` marker printed.
    WM_ALT=0
    grep -a -qF -- "wnd: alt-tab id=" "$SER_B" && WM_ALT=1
    # 2) The kernel did NOT consume the chord (no `dui: alt-tab` from the
    #    keyboard path — the dui rows here are the monitor `dui` listing, which
    #    prints `dui: window` rows, never `dui: alt-tab`).
    KERNEL_ALT=0
    grep -a -qF -- "dui: alt-tab" "$SER_B" && KERNEL_ALT=1
    # 3) The keyboard seam fanned the key out (kind 21) AND the WM stayed
    #    seated + pacing (present markers ride the long dwells).
    KEYFAN=0; PRESENT=0
    grep -a -qE -- "key_fan=[1-9][0-9]*" "$SER_B" && KEYFAN=1
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    # 4) The kernel applied the WM's ALT_TAB (the cmd-5 counter is nonzero in
    #    the `wm` observability row — an applied WM decision, not a dropped one).
    APPLY=0
    grep -a -qE -- "alt_tab=[1-9][0-9]*" "$SER_B" && APPLY=1
    if [ "$WM_ALT" = 1 ] && [ "$KERNEL_ALT" = 0 ] && [ "$KEYFAN" = 1 ] && [ "$PRESENT" = 1 ] && [ "$APPLY" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS6 Gate A live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  alt_tab_shim=$ALT  win2=$WIN2"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven Alt+Tab):"
    echo "  runner rc=$RC_B  wm_alt=$WM_ALT  kernel_alt=$KERNEL_ALT  key_fan=$KEYFAN  wm_present=$PRESENT  applied=$APPLY"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd6-altab-drain: PASS — the shim still self-cycles Alt+Tab (no WM) AND with WND.BIN registered the WM decided the switch target (the kernel did not)"
    else
        echo "verify-live-wnd6-altab-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: shim alt-tab rows]" >> "$REPORT"
    grep -a "dui: alt-tab" "$SER_A" | head -4 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM's alt-tab decision + counters]" >> "$REPORT"
    grep -a -E "wnd: (alt-tab|present)|wm: (key_fan|alt_tab)|dui: alt-tab" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi