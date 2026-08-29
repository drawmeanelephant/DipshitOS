#!/usr/bin/env bash
#
# verify-live-wnd6-tray-drain.sh — M32 WMS6 Gate E (issue #626) class-B gate:
# the tray widgets drain into WND.BIN (the final WMS6 chrome gate).
#
# Gates A-D drained the keyboard, click, hover, and dock chrome. Gate E drains
# the tray WIDGET CONTENT: the clock string, theme letter, and clipboard
# indicator. While a WM is registered the kernel's `drain` (which refreshed
# the tray clock) is gated OFF — the tray froze. The WM now owns the content:
# every `tray_refresh_every` COMPOSITE_TICK (1 Hz ticks = 10 s) it re-decides
# from its own state (the clock string from its tick counter via the same
# minute-rollover formula the shim uses, the clipboard indicator from a
# sys_clipboard_get probe) and issues new slot-65 TRAY (cmd 10); the kernel
# clamps + stores + repaints. The kernel's tray render is source-selected:
# WM-declared values when set, shim-derived otherwise (no-WM = byte-identical).
#
# Fully CI-runnable with NO Accessibility trust — this gate needs no pointer
# injection (it is time-driven, not input-driven).
#
# Two boots prove both halves:
#   * Boot A (shim regression, no WM): probe `dui tray-state` — the clock is
#     kernel-derived (`clock_set=no`, a valid HH:MM string). Zero regression.
#   * Boot B (WM-driven): `wnd start` + NOTEPAD. Probe 1 (~20 s): the WM has
#     already issued its first TRAY (`wm: tray=1`, `clock_set=yes`). Then
#     `clip hello` fills the clipboard; probe 2 (~40 s): the WM's next refresh
#     boundary picked it up (`wm: tray=2`, `clip=yes clip_set=yes`). Serial
#     proof: `wnd: tray clock=..` (WM decided), the probe clock MATCHES the
#     marker clock (the WM's string is what renders), and the tray counter
#     GREW between the probes (the clock REFRESHES under the WM).
#
# Zero regression: no WM registered -> the shim tray render is byte-identical
# (boot A); the HH:MM/theme/clipboard blits unchanged.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd6-tray-drain.sh
# Evidence: artifacts/live-wnd6-tray-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd6-tray-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/626

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd6-tray-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd6-tray-report.txt)"

echo "=== verify-live-wnd6-tray-drain: M32 WMS6 Gate E — the tray widgets drain into WND.BIN (issue #626) ==="

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
gate_begin live-wnd6-tray
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
        > "$(art live-wnd6-tray-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd6-tray-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the shell idle shim owns the tray: `dui tray-state` shows a
# KERNEL-derived clock (`clock_set=no`, valid HH:MM). The probe is pure (does
# not change anything). Zero regression.
echo "--- boot A: no WM — the tray clock stays kernel-derived (zero regression) ---"
printf 'dui tray-state\necho tray-a-done\n' > "$RUN_DIR/sA.txt"
EXPECT_A='echo tray-a-done'
set +e
run_boot A \
    --script "$RUN_DIR/sA.txt" \
    --script-expect "$EXPECT_A" --timeout 180
RC_A=$?
set -e
A_OK=0
A_SHIM=0
A_FAULT=0
SER_A="$(art live-wnd6-tray-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The tray clock is kernel-derived: `clock_set=no` with a valid HH:MM.
    grep -a -qE -- "dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=no" "$SER_A" && A_SHIM=1
    # 2) No real fault/panic (exclude the benign `efault` uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_SHIM" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven tray -------------------------------------------------
# With WND.BIN registered the kernel's drain (the shim tray refresher) is
# gated OFF — the WM owns the content. Probe 1 (~20 s): the WM has issued its
# first TRAY (tray=1, clock_set=yes). Then `clip hello` fills the clipboard;
# probe 2 (~40 s): the WM's next 10 s refresh boundary picked it up (tray=2,
# clip=yes clip_set=yes). The probe clock must MATCH the marker clock — the
# WM's string is what renders.
echo "--- boot B: the WM owns the tray clock + clipboard indicator (the kernel does not) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'wm\ndui tray-state\nclip hello\necho tray-go\n' > "$RUN_DIR/s2-B.txt"
printf 'wm\ndui tray-state\necho tray-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "tray-go" --script3-delay 20 \
    --script-expect "tray-done" --timeout 240
RC_B=$?
set -e
B_OK=0
B_WM=0
B_APPLY=0
B_CLOCK_SET=0
B_CLIP=0
B_MATCH=0
B_REFRESH=0
B_PRESENT=0
SER_B="$(art live-wnd6-tray-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided the tray content: its `wnd: tray clock=` marker printed.
    grep -a -qE -- "wnd: tray clock=" "$SER_B" && B_WM=1
    # 2) The kernel APPLIED the WM's TRAY (cmd-10 counter nonzero in the `wm`
    #    row — the tray content came from WM decisions, not the shim).
    grep -a -qE -- "wm: .*tray=[1-9][0-9]*" "$SER_B" && B_APPLY=1
    # 3) The rendered clock is the WM's (`clock_set=yes` in the probe).
    grep -a -qE -- "dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=yes" "$SER_B" && B_CLOCK_SET=1
    # 4) The clipboard indicator flipped to the WM's `clip=yes` decision after
    #    `clip hello` (the WM's sys_clipboard_get probe caught the fill).
    grep -a -qE -- "dui tray-state: .*clip=yes clip_set=yes" "$SER_B" && B_CLIP=1
    # 5) The rendered clock MATCHES the WM's marker clock (the WM's string is
    #    what renders — not a kernel-derived value).
    MCLK="$(grep -a -oE 'wnd: tray clock=[0-9][0-9]:[0-9][0-9]' "$SER_B" | tail -1 | cut -d= -f2 || true)"
    SCLK="$(grep -a -oE 'dui tray-state: clock=[0-9][0-9]:[0-9][0-9]' "$SER_B" | tail -1 | cut -d= -f2 || true)"
    if [ -n "$MCLK" ] && [ -n "$SCLK" ] && [ "$MCLK" = "$SCLK" ]; then
        B_MATCH=1
    fi
    # 6) The tray counter GREW between the two `wm` probes (the WM kept
    #    re-deciding — the clock REFRESHES under the WM, it does not freeze).
    TRAY_VALS=($(grep -a -oE 'tray=[0-9]+' "$SER_B" | cut -d= -f2 || true))
    if [ "${#TRAY_VALS[@]}" -ge 2 ]; then
        T1="${TRAY_VALS[0]}"
        T2="${TRAY_VALS[${#TRAY_VALS[@]}-1]}"
        if [ "$T1" -ge 1 ] 2>/dev/null && [ "$T2" -gt "$T1" ] 2>/dev/null; then
            B_REFRESH=1
        fi
    fi
    # 7) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B" && B_PRESENT=1
    if [ "$B_WM" = 1 ] && [ "$B_APPLY" = 1 ] && [ "$B_CLOCK_SET" = 1 ] && [ "$B_CLIP" = 1 ] && [ "$B_MATCH" = 1 ] && [ "$B_REFRESH" = 1 ] && [ "$B_PRESENT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS6 Gate E live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  kernel_clock=$A_SHIM  fault=$A_FAULT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven tray):"
    echo "  runner rc=$RC_B  wm_tray=$B_WM  applied=$B_APPLY  clock_set=$B_CLOCK_SET  clip_flip=$B_CLIP  clock_match=$B_MATCH  refresh=$B_REFRESH  wm_present=$B_PRESENT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd6-tray-drain: PASS — the shim tray stays kernel-derived (no WM) AND with WND.BIN registered the WM owns the clock string + clipboard indicator, the counter grew (clock refresh), and the WM's string is what renders"
    else
        echo "verify-live-wnd6-tray-drain: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the kernel-derived tray clock]" >> "$REPORT"
    grep -a -E "dui tray-state" "$SER_A" | head -3 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM decision + applied counter + flipped indicator]" >> "$REPORT"
    grep -a -E "wnd: tray|wm: .*tray=|dui tray-state" "$SER_B" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi
