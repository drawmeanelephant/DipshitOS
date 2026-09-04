#!/usr/bin/env bash
#
# verify-live-wnd2-mission-control.sh -- WM2 mission-control overview
# (Self-hosting Lane 1, issue #707 card 2) class-B gate: the grid of
# current-workspace windows, proven on real VZ.
#
# A Ctrl+F12 hotkey scales all current-workspace user windows into a grid of
# preview cards (the shared wnd_core grid rules — the kernel paints them, the
# WM hit-tests the SAME rects); click focuses+raises, drag onto the workspace
# strip moves the window there and switches to it, Esc/hotkey exits. Zero new
# syscall slots (slot-65 OVERVIEW, cmd 21); the WM-side mirror is 8-wide
# (ids 2-9, the WM1 ceiling).
#
# FOUR headless boots with --screen (GPU armed so REGISTER seats) + the
# custom-virtio INPUT queue (keys ride --input-chords incl. the new
# `ctrl-f12` token = LCtrl + HID F12 0x45; pointer rides --pointer-virtio):
#   Boot A (shim, NO WM): Ctrl+F12 is NOT consumed as overview (no
#            `wnd: overview-*`, no fault) — the chord falls through to the
#            focused window as a plain key event.
#   Boot B (WM + 2 M21DEMO windows): Ctrl+F12 enters (`wnd:
#            overview-enter n=2`), then a click on card 1 focuses it (`wnd:
#            overview-focus id=`) and closes the grid; `wm` shows
#            `overview=` >= 2 (enter + focus applied).
#   Boot C (WM + 2 M21DEMO windows): Ctrl+F12 enters, then a press-drag
#            from card 0 onto the WS-1 strip button moves window 2 there
#            (`wnd: overview-move id=2 ws=1`) and the desktop follows
#            (the `dui` listing row for window A reads `ws=1`).
#   Boot D (WM + 2 M21DEMO windows): Ctrl+F12 then Esc enters + exits
#            (`wnd: overview-enter` + `wnd: overview-exit`, `overview=` = 2).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art wnd2-mission-control-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wnd2-mission-control-report.txt)"

echo "=== verify-live-wnd2-mission-control: WM2 mission-control overview (issue #707 card 2) on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-wnd2-mission-control
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    # M21 W11 isolation (#990, claim #997): the shell persists window state
    # to WINDOWS.SAV on the share every ~300 idle cycles — boot A's demo
    # windows leaked into boots B/C/D as PHANTOM boot-time restores
    # (synthetic owner=99), which is what the overview's n=2-vs-n=3 flake
    # actually was. Each boot starts from the seeded share, not the
    # previous boot's session.
    rm -f "$RUN_DIR/share/WINDOWS.SAV"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        "$@" \
        > "$(art live-wnd2-mission-control-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd2-mission-control-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim regression (no WM) ------------------------------------------
# Ctrl+F12 with no WM seated must not open any grid (the kernel has no
# overview state without OVERVIEW decisions) and must not fault.
echo "--- boot A: no WM — Ctrl+F12 is harmless (no grid, no fault) ---"
printf 'exec M21DEMO.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui\nwm\necho chord-a\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\necho done-a\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo done-a'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12" --input-chords-after "chord-a" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "chord-a" --script3-delay 15 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
SER_A="$(art live-wnd2-mission-control-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    A_NOGRID=0
    grep -a -qF -- "wnd: overview" "$SER_A" || A_NOGRID=1
    A_FAULT=0
    grep -a -qE -- "(panic|abort|kernel fault)" "$SER_A" && A_FAULT=1
    A_WIN2=0
    grep -a -qF -- "m21demo: loop ok" "$SER_A" && A_WIN2=1
    echo "boot A checks: no_grid=$A_NOGRID no_fault=$([ "$A_FAULT" = 0 ] && echo 1 || echo 0) demo_ok=$A_WIN2"
    if [ "$A_NOGRID" = 1 ] && [ "$A_FAULT" = 0 ] && [ "$A_WIN2" = 1 ]; then
        A_OK=1
    fi
fi

# --- boot B: WM-driven overview — enter + click-to-focus -----------------------
# Grid math for the 2 M21DEMO windows (1280x720 scanout): 2 cols x 1 row,
# card_w=616 card_h=656, card 0 x 32..648, card 1 x 656..1272, y 8..664.
# The click at (964,336) is card 1's center.
echo "--- boot B: WND.BIN registered — Ctrl+F12 enters, click focuses card 1 ---"
printf 'wnd start\nexec M21DEMO.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'ps\ndui\nwm\necho chord-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\nwm\necho overview-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "wnd: wallpaper loaded" --script2-delay 30 \
    --input-chords "ctrl-f12" --input-chords-after "chord-go" --input-chords-delay 2 \
    --pointer-virtio "964,336,c" --pointer-virtio-after "wnd: overview-enter" \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chord-go" --script3-delay 40 \
    --script-expect "overview-done" --timeout 280
RC_B=$?
set -e
B_OK=0
SER_B="$(art live-wnd2-mission-control-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    B_ENTER=0; B_FOCUS=0; B_APPLY=0; B_KEYFAN=0; B_PTRFAN=0; B_PRESENT=0
    grep -a -qF -- "wnd: overview-enter n=2" "$SER_B" && B_ENTER=1
    grep -a -qF -- "wnd: overview-focus id=" "$SER_B" && B_FOCUS=1
    grep -a -qE -- "overview=[1-9][0-9]*" "$SER_B" && B_APPLY=1
    grep -a -qE -- "key_fan=[1-9][0-9]*" "$SER_B" && B_KEYFAN=1
    grep -a -qE -- "wm: ptr_fan=[1-9][0-9]*" "$SER_B" && B_PTRFAN=1
    grep -a -qF -- "wnd: present" "$SER_B" && B_PRESENT=1
    echo "boot B checks: enter=$B_ENTER focus=$B_FOCUS overview_counter=$B_APPLY key_fan=$B_KEYFAN ptr_fan=$B_PTRFAN present=$B_PRESENT"
    if [ "$B_ENTER" = 1 ] && [ "$B_FOCUS" = 1 ] && [ "$B_APPLY" = 1 ] && [ "$B_KEYFAN" = 1 ] && [ "$B_PTRFAN" = 1 ] && [ "$B_PRESENT" = 1 ]; then
        B_OK=1
    fi
fi

# --- boot C: WM-driven overview — drag card 0 onto the WS-1 strip button ------
# Card 0 center is (340,336); the WS-1 strip button spans x 442..860 at
# y 672..700 (three 418px thirds past the 24px dock). The drag moves window
# 2 to workspace 1 and the desktop follows it there.
echo "--- boot C: WND.BIN registered — drag card 0 to WS 1 moves + switches ---"
printf 'wnd start\nexec M21DEMO.BIN\n' > "$RUN_DIR/script-C.txt"
printf 'dui\nwm\necho chord-go\n' > "$RUN_DIR/s2-C.txt"
printf 'dui\nwm\necho move-done\n' > "$RUN_DIR/s3-C.txt"
set +e
run_boot C \
    --script "$RUN_DIR/script-C.txt" \
    --script2 "$RUN_DIR/s2-C.txt" --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12" --input-chords-after "chord-go" --input-chords-delay 2 \
    --pointer-virtio "340,336,d;651,686,u" --pointer-virtio-after "wnd: overview-enter" \
    --script3 "$RUN_DIR/s3-C.txt" --script3-after "chord-go" --script3-delay 40 \
    --script-expect "move-done" --timeout 280
RC_C=$?
set -e
C_OK=0
SER_C="$(art live-wnd2-mission-control-serial-C.log)"
if [ "$RC_C" = 0 ] && [ -f "$SER_C" ]; then
    C_ENTER=0; C_MOVE=0; C_WS=0; C_APPLY=0
    grep -a -qF -- "wnd: overview-enter n=2" "$SER_C" && C_ENTER=1
    grep -a -qF -- "wnd: overview-move id=2 ws=1" "$SER_C" && C_MOVE=1
    # The `dui` listing row for window A keeps its open rect but now reads
    # ws=1 (the kernel applied the WM's move + switch).
    grep -a -qE -- "rect=64,64,512,384.*ws=1" "$SER_C" && C_WS=1
    grep -a -qE -- "overview=[1-9][0-9]*" "$SER_C" && C_APPLY=1
    echo "boot C checks: enter=$C_ENTER move=$C_MOVE ws_switch=$C_WS overview_counter=$C_APPLY"
    if [ "$C_ENTER" = 1 ] && [ "$C_MOVE" = 1 ] && [ "$C_WS" = 1 ] && [ "$C_APPLY" = 1 ]; then
        C_OK=1
    fi
fi

# --- boot D: WM-driven overview — Esc exits ------------------------------------
echo "--- boot D: WND.BIN registered — Ctrl+F12 then Esc enters + exits ---"
printf 'wnd start\nexec M21DEMO.BIN\n' > "$RUN_DIR/script-D.txt"
printf 'dui\nwm\necho chord-go\n' > "$RUN_DIR/s2-D.txt"
printf 'dui\nwm\necho exit-done\n' > "$RUN_DIR/s3-D.txt"
set +e
run_boot D \
    --script "$RUN_DIR/script-D.txt" \
    --script2 "$RUN_DIR/s2-D.txt" --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12,escape" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-D.txt" --script3-after "chord-go" --script3-delay 25 \
    --script-expect "exit-done" --timeout 260
RC_D=$?
set -e
D_OK=0
SER_D="$(art live-wnd2-mission-control-serial-D.log)"
if [ "$RC_D" = 0 ] && [ -f "$SER_D" ]; then
    D_ENTER=0; D_EXIT=0; D_APPLY=0
    grep -a -qF -- "wnd: overview-enter n=2" "$SER_D" && D_ENTER=1
    grep -a -qF -- "wnd: overview-exit" "$SER_D" && D_EXIT=1
    grep -a -qE -- "overview=[1-9][0-9]*" "$SER_D" && D_APPLY=1
    echo "boot D checks: enter=$D_ENTER exit=$D_EXIT overview_counter=$D_APPLY"
    if [ "$D_ENTER" = 1 ] && [ "$D_EXIT" = 1 ] && [ "$D_APPLY" = 1 ]; then
        D_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WM2 mission-control live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM: enter + click-to-focus):"
    echo "  runner rc=$RC_B"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot C (WM: drag-to-workspace move):"
    echo "  runner rc=$RC_C"
    echo "  RESULT: $([ "$C_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot D (WM: Esc exits):"
    echo "  runner rc=$RC_D"
    echo "  RESULT: $([ "$D_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ] && [ "$C_OK" = 1 ] && [ "$D_OK" = 1 ]; then
        echo "verify-live-wnd2-mission-control: PASS — the shim ignores Ctrl+F12 AND with WND.BIN registered the WM entered the grid, click-focused a card, drag-moved a card across workspaces, and Esc-exited (the kernel applied every decision)"
    else
        echo "verify-live-wnd2-mission-control: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
for T in A B C D; do
    SER_VAR="SER_$T"
    SER="${!SER_VAR}"
    if [ -f "$SER" ]; then
        echo "[serial $T: overview markers + counters]" >> "$REPORT"
        grep -a -E "wnd: overview|wm: .*overview=|ws=1" "$SER" | head -8 >> "$REPORT" || true
    fi
done

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ] && [ "$C_OK" = 1 ] && [ "$D_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi
