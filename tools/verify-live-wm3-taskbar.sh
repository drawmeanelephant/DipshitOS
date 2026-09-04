#!/usr/bin/env bash
#
# verify-live-wm3-taskbar.sh — WM3 (issue #707 card 3) class-B gate: the
# taskbar shows per-window entries, workspace-aware, and the entry click
# drains into WND.BIN.
#
# WM3 (Lane 1, umbrella #707): the bottom taskbar's entries are REAL
# taskbar entries — current-workspace user windows only, enumerated
# ID-ASCENDING by the shared wnd_core rule (taskbar_entry_rect /
# taskbar_entry_at / taskbar_title_slice), the focused entry carrying the
# active fill + 2px underline, a minimized entry carrying the darker fill
# + restore dot. The entry click decision is the WM's (like the dock, WMS8
# deleted the shim's click decisions): the WM hit-tests the SAME shared
# rects and issues new slot-65 TASKBAR (cmd 12); the kernel applies the
# SAME clamped chain a shim click would run (restore-if-minimized, else
# focus + raise). `dui taskbar` reports the exact render enumeration; the
# `wm` row carries the taskbar= counter.
#
# Fully CI-runnable with NO Accessibility trust: the click rides the
# headless --pointer-virtio channel (claim 9367).
#
# Three boots prove the halves:
#   * Boot A (shim regression, no WM): NOTEPAD on ws 0; `dui taskbar`
#     shows entry=0 id=2 focused=1; `dui minimize 2` flips minimized=1
#     (the restore dot); `dui ws 1` empties the bar (entries=0 — the
#     workspace filter); `dui ws 0` + `dui restore 2` bring it back.
#     Zero regression.
#   * Boot B1 (WM-driven FOCUS click): `wnd start` + NOTEPAD (id 2) +
#     CALC (id 3) — CALC is focused; a REAL click on entry 0 (120, 710 —
#     inside the entry-0 rect x=80..160, y=702..718) makes the WM decide
#     (`wnd: taskbar id=2 restore=0`), the kernel applies (wm: taskbar=1)
#     and NOTEPAD refocuses (focused=2).
#   * Boot B2 (WM-driven RESTORE click): same setup, then `dui minimize 2`
#     and the same click RESTORES it (restore=1, focused=2, visible).
#
# Zero regression: no WM registered -> the render enumeration + bar blit
# are the same rule (boot A); the shim has no taskbar click path (WMS8
# chrome ownership — unchanged).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wm3-taskbar.sh
# Evidence: artifacts/live-wm3-taskbar-{A,B1,B2}-{run.txt,serial.log},
#           artifacts/live-wm3-taskbar-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/707

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wm3-taskbar-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wm3-taskbar-report.txt)"

echo "=== verify-live-wm3-taskbar: WM3 — taskbar depth: titles, indicators, workspace filter, WM click-to-focus/restore (issue #707 card 3) ==="

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
gate_begin live-wm3-taskbar
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
        > "$(art live-wm3-taskbar-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wm3-taskbar-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# Taskbar entry 0 (the first current-workspace entry after the 3-cell
# switcher): the shared wnd_core rect is x=80..160, y=702..718 — its
# center is (120, 710).
ENTRY0_CLICK="120,710,c"

# --- boot A: shim regression (no WM) ------------------------------------------
# No WM seated -> the render enumeration + bar blit follow the shared rule:
# NOTEPAD is entry 0 focused; minimizing flips the minimized indicator;
# switching to ws 1 empties the bar (the workspace filter). The 20 s dwell
# lets the ring drain before the report lands.
echo "--- boot A: no WM — the taskbar enumeration follows the shared rule (zero regression) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui taskbar\ndui minimize 2\ndui taskbar\ndui ws 1\ndui taskbar\ndui ws 0\ndui restore 2\ndui taskbar\necho taskbar-a-go\n' > "$RUN_DIR/s2-A.txt"
EXPECT_A='echo taskbar-a-go'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_FOCUSED=0
A_MIN=0
A_WS_EMPTY=0
A_RESTORED=0
A_FAULT=0
SER_A="$(art live-wm3-taskbar-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) NOTEPAD is entry 0, focused, not minimized (the first report).
    grep -a -qF -- "dui taskbar: entry=0 id=2 focused=1 minimized=0" "$SER_A" && A_FOCUSED=1
    # 2) The minimize flips the indicator (the second report shows
    #    minimized=1 and the focused flag drops with the hide).
    grep -a -qF -- "dui taskbar: entry=0 id=2 focused=0 minimized=1" "$SER_A" && A_MIN=1
    # 3) The workspace filter: ws 1 has NO entries (the report between the
    #    `dui ws 1` and `dui ws 0`).
    grep -a -qF -- "dui taskbar: ws=1 entries=0" "$SER_A" && A_WS_EMPTY=1
    # 4) The restore brings the entry back, un-minimized.
    grep -a -qF -- "dui taskbar: ws=0 entries=1" "$SER_A" && A_RESTORED=1
    # 5) No real fault/panic (exclude the benign `efault` uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_FOCUSED" = 1 ] && [ "$A_MIN" = 1 ] && [ "$A_WS_EMPTY" = 1 ] && [ "$A_RESTORED" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B1: the WM-driven taskbar FOCUS click ---------------------------------
# WND.BIN registered; NOTEPAD (id 2) + CALC (id 3) — CALC is focused. A REAL
# click on entry 0 (NOTEPAD's rect) makes the WM hit-test the shared rects,
# decide, and issue TASKBAR (cmd 12); the kernel applies the focus chain.
echo "--- boot B1: a WM-driven taskbar click focuses the window the WM decided (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\nexec CALC.BIN\n' > "$RUN_DIR/script-B1.txt"
printf 'dui\nwm\necho taskbar-go\n' > "$RUN_DIR/s2-B1.txt"
printf 'dui\nwm\necho taskbar-b1-done\n' > "$RUN_DIR/s3-B1.txt"
set +e
run_boot B1 \
    --script "$RUN_DIR/script-B1.txt" \
    --script2 "$RUN_DIR/s2-B1.txt" --script2-after "calc: ready" --script2-delay 20 \
    --pointer-virtio "$ENTRY0_CLICK" --pointer-virtio-after "taskbar-go" \
    --script3 "$RUN_DIR/s3-B1.txt" --script3-after "taskbar-go" --script3-delay 20 \
    --script-expect "taskbar-b1-done" --timeout 300
RC_B1=$?
set -e
B1_OK=0
WM_CLICK=0
APPLY=0
FOCUSED=0
PRESENT1=0
SER_B1="$(art live-wm3-taskbar-serial-B1.log)"
if [ "$RC_B1" = 0 ] && [ -f "$SER_B1" ]; then
    # 1) The WM decided the click: `wnd: taskbar id=2 restore=0` (its
    #    mirror shows the window visible — focus, not restore).
    grep -a -qF -- "wnd: taskbar id=2 restore=0" "$SER_B1" && WM_CLICK=1
    # 2) The kernel APPLIED the WM's TASKBAR (cmd-12 counter nonzero in the
    #    `wm` row — the focus came from a WM decision, not a kernel click).
    grep -a -qE -- "taskbar=[1-9][0-9]*" "$SER_B1" && APPLY=1
    # 3) The click refocused NOTEPAD (the post-click dui header: CALC was
    #    focused before — id 3).
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_B1" && FOCUSED=1
    # 4) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B1" && PRESENT1=1
    if [ "$WM_CLICK" = 1 ] && [ "$APPLY" = 1 ] && [ "$FOCUSED" = 1 ] && [ "$PRESENT1" = 1 ]; then
        B1_OK=1
    fi
fi

# --- boot B2: the WM-driven taskbar RESTORE click --------------------------------
# Same setup, then `dui minimize 2` (the kernel mirrors the hide to the WM)
# and the same click on entry 0 — the WM decides restore=1; the kernel
# applies the restore chain (visible + focused).
echo "--- boot B2: a WM-driven taskbar click restores the minimized window the WM decided ---"
printf 'wnd start\nexec NOTEPAD.BIN\nexec CALC.BIN\n' > "$RUN_DIR/script-B2.txt"
printf 'dui minimize 2\ndui\necho taskbar-go\n' > "$RUN_DIR/s2-B2.txt"
printf 'dui\nwm\necho taskbar-b2-done\n' > "$RUN_DIR/s3-B2.txt"
set +e
run_boot B2 \
    --script "$RUN_DIR/script-B2.txt" \
    --script2 "$RUN_DIR/s2-B2.txt" --script2-after "calc: ready" --script2-delay 20 \
    --pointer-virtio "$ENTRY0_CLICK" --pointer-virtio-after "taskbar-go" \
    --script3 "$RUN_DIR/s3-B2.txt" --script3-after "taskbar-go" --script3-delay 20 \
    --script-expect "taskbar-b2-done" --timeout 300
RC_B2=$?
set -e
B2_OK=0
WM_RESTORE=0
APPLY2=0
RESTORED=0
PRESENT2=0
SER_B2="$(art live-wm3-taskbar-serial-B2.log)"
if [ "$RC_B2" = 0 ] && [ -f "$SER_B2" ]; then
    # 1) The WM decided the restore: `wnd: taskbar id=2 restore=1` (its
    #    mirror shows the window hidden — the restore bit).
    grep -a -qF -- "wnd: taskbar id=2 restore=1" "$SER_B2" && WM_RESTORE=1
    # 2) The kernel APPLIED the WM's TASKBAR (the cmd-12 counter).
    grep -a -qE -- "taskbar=[1-9][0-9]*" "$SER_B2" && APPLY2=1
    # 3) NOTEPAD restored + focused (the post-restore dui header).
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_B2" && RESTORED=1
    # 4) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_B2" && PRESENT2=1
    if [ "$WM_RESTORE" = 1 ] && [ "$APPLY2" = 1 ] && [ "$RESTORED" = 1 ] && [ "$PRESENT2" = 1 ]; then
        B2_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WM3 taskbar live report ---"
    echo "boot A (shim regression, no WM):"
    echo "  runner rc=$RC_A  focused=$A_FOCUSED  minimized=$A_MIN  ws_filter=$A_WS_EMPTY  restored=$A_RESTORED  fault=$A_FAULT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B1 (WM-driven focus click):"
    echo "  runner rc=$RC_B1  wm_click=$WM_CLICK  applied=$APPLY  refocused=$FOCUSED  wm_present=$PRESENT1"
    echo "  RESULT: $([ "$B1_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B2 (WM-driven restore click):"
    echo "  runner rc=$RC_B2  wm_restore=$WM_RESTORE  applied=$APPLY2  restored=$RESTORED  wm_present=$PRESENT2"
    echo "  RESULT: $([ "$B2_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B1_OK" = 1 ] && [ "$B2_OK" = 1 ]; then
        echo "verify-live-wm3-taskbar: PASS — the taskbar enumeration follows the shared rule (workspace filter + focused/minimized indicators) AND with WND.BIN registered the WM decided the entry clicks (focus, then restore) while the kernel only applied"
    else
        echo "verify-live-wm3-taskbar: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the render enumeration across minimize/workspace-switch/restore]" >> "$REPORT"
    grep -a -E "dui taskbar: (ws=|entry=)" "$SER_A" | head -8 >> "$REPORT" || true
fi
if [ -f "$SER_B1" ]; then
    echo "[serial B1: the WM focus decision + applied counter + refocus]" >> "$REPORT"
    grep -a -E "wnd: taskbar|wm: .*taskbar=|dui: windows=|wnd: present" "$SER_B1" | head -8 >> "$REPORT" || true
fi
if [ -f "$SER_B2" ]; then
    echo "[serial B2: the WM restore decision + applied counter + restore]" >> "$REPORT"
    grep -a -E "wnd: taskbar|wm: .*taskbar=|dui: windows=|wnd: present" "$SER_B2" | head -8 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B1_OK" = 1 ] && [ "$B2_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi
