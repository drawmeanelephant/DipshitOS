#!/usr/bin/env bash
#
# verify-live-wnd5-gate2-policy.sh -- M32 WMS5 Gate 2 (issue #625, claim
# 4278) class-B gate: the geometry-policy drain-out proven live on real VZ.
#
# The W1–W16 (M21) matrix drives geometry through `dui` monitor commands ->
# kernel functions directly (the established EL1h-monitor precedent; the
# chords themselves are host-tested in input.zig). This gate re-runs the
# SAME assertions with WND.BIN registered — proving the matrix behaves
# identically while a WM is seated (zero regression), PLUS a WM-driven
# interaction proving the WM — not the kernel — decides geometry from the
# kind-21 WM_KEY stream:
#
#   * Boot A (the registered matrix): `wnd start` + `exec NOTEPAD.BIN`, then
#     the W1/W2/W3/W6/W4 dui assertions (`dui tile 2`, `dui master`,
#     `dui minimize 2`, `dui restore 2`, `dui maximize 2`, `dui ws 1`) — the
#     same commands the m21-tile-master / m21-minimize-ws gates run, now with
#     WND.BIN registered. Serial proof: the dui lines print identically AND
#     the kernel's keyboard geometry consumers are gated off (the WM owns the
#     chords), so no `dui: tile=` keyboard path fires.
#   * Boot B (the WM-driven policy): `wnd start` + `exec NOTEPAD.BIN`, then
#     `--input-chords "ctrl-t"` — a REAL Ctrl+T over the virtio keyboard.
#     The kernel must NOT consume it (its chord pending flags are gated
#     behind !wm_owns_input); the WM receives kind-21 WM_KEY, decides tile,
#     and issues SET_WINDOW rects. Serial proof: the WM's `wnd: tile` marker
#     and the `wm: key_fan=N` / `set_state=M` counters — the window's rect
#     CHANGES to the tiled master rect (24,0,837,700), driven by the WM.
#
# Zero regression: no WM registered -> the keyboard chords + dui commands
# behave exactly as pre-WMS5 (the W1–W16 gates are untouched and stay green);
# the `dui`-driven geometry functions still work while a WM is seated (they
# are monitor commands, not input paths).
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-wnd5-gate2-policy.sh
#
# Evidence: artifacts/live-wnd5-gate2-report.txt (the report),
# artifacts/live-wnd5-gate2-{A,B}-{run.txt,serial.log}.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-wnd5-gate2-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wnd5-gate2-report.txt)"

echo "=== verify-live-wnd5-gate2: M32 WMS5 Gate 2 — geometry policy drain-out (issue #625) on VZ ==="

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
gate_begin live-wnd5-gate2
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
        > "$(art live-wnd5-gate2-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e`. Re-arming inside the
    # function kills the whole gate on a failing boot (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd5-gate2-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: the registered-WM W1–W16 matrix ----------------------------------
# The SAME dui assertions the m21 gates run, with WND.BIN registered. The
# `wm` observability proves the WM is seated + the keyboard seam is live;
# the dui rows prove the kernel functions behave identically while seated.
# NB: the ring only rotates on 1 Hz VZ timer ticks (the EL1h worker spins
# 2 M nops between preemptions), and the WM drains ONE COMPOSITE_TICK per
# scheduled run — so a present (a marker per 2 ticks) needs several
# seconds of wall-clock. The WMS4 gate's settled pattern (claim 5069) is
# to give a long dwell BEFORE the assertion script so the markers
# accumulate; a short dwell captures the WM mid-drain (presents=0) and
# the gate fails on a healthy WM.
echo "--- boot A: W1–W16 matrix re-run against the registered WM ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui tile 2\ndui master\ndui minimize 2\ndui restore 2\ndui maximize 2\ndui ws 1\ndui ws 0\nwm\necho matrix-a\n' > "$RUN_DIR/s2-A.txt"
EXPECT_A='echo matrix-a'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --script-expect "$EXPECT_A" --timeout 240
RC_A=$?
set -e
A_OK=0
SER_A="$(art live-wnd5-gate2-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The WM is seated + pacing (the WMS3 markers: registered + at least
    #    one present — the 20 s dwell is what lets the drained ticks ride to
    #    a present).
    REG=0; PRESENT=0
    grep -a -qF -- "wnd: registered" "$SER_A" && REG=1
    grep -a -qF -- "wnd: present" "$SER_A" && PRESENT=1
    # 2) The W1/W2 matrix rows printed (identical to the shim gates).
    TILE=0; MASTER=0
    grep -a -qF -- "dui tile: id=2 mode=on master=2" "$SER_A" && TILE=1
    grep -a -qF -- "dui master: side=" "$SER_A" && MASTER=1
    # 3) The W3 minimize/restore + W6 maximize rows printed.
    MIN=0; REST=0; MAX=0
    grep -a -qF -- "dui minimize: minimized id=2" "$SER_A" && MIN=1
    grep -a -qF -- "dui restore: restored id=2" "$SER_A" && REST=1
    grep -a -qF -- "dui maximize: id=2 max=on" "$SER_A" && MAX=1
    # 4) The W4 workspace rows printed.
    WS=0
    grep -a -qF -- "dui ws: workspace=1" "$SER_A" && WS=1
    # 5) The `wm` observability shows the keyboard seam is live (the WM
    #    received raw keys — NOTEPAD's user typing is not present, but the
    #    fan-out counters exist in the report shape).
    KEYFAN=0
    grep -a -qE -- "key_fan=[0-9]+" "$SER_A" && KEYFAN=1
    if [ "$REG" = 1 ] && [ "$PRESENT" = 1 ] && [ "$TILE" = 1 ] && [ "$MASTER" = 1 ] && [ "$MIN" = 1 ] && [ "$REST" = 1 ] && [ "$MAX" = 1 ] && [ "$WS" = 1 ] && [ "$KEYFAN" = 1 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven keyboard policy ------------------------------------
# A REAL Ctrl+T over the virtio keyboard. The kernel must NOT consume it
# (the pending flags are gated behind !wm_owns_input); the WM receives kind
# 21, decides tile, and issues SET_WINDOW — the window's rect becomes the
# tiled master rect (24,0,837,700).
#
# Also settled: script2 waits 20 s (the ring's slow rotation lets the WM
# drain + present), then dumps `dui`/`wm` and echoes `chord-go`. The chord
# is injected AFTER that marker (so the WM is seated, drained, and parked
# in `sys_wait_event`), then a post-chord script3 waits another long settle
# and dumps `dui`/`wm` again — the tiled rect is only visible after the WM
# schedules, decodes kind 21, and issues SET_WINDOW.
echo "--- boot B: a WM-driven Ctrl+T tiles the focused window (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui\nwm\necho chord-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\nwm\ntasks\nprocs\necho ctrl-t-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --input-chords "ctrl-t" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chord-go" --script3-delay 20 \
    --script-expect "ctrl-t-done" --timeout 260
RC_B=$?
set -e
B_OK=0
SER_B="$(art live-wnd5-gate2-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided: its `wnd: tile` marker printed.
    WM_TILE=0
    grep -a -qF -- "wnd: tile" "$SER_B" && WM_TILE=1
    # 2) The kernel did NOT consume the chord (no `dui: tile=` from the
    #    keyboard path — the dui rows here are the monitor `dui` listing,
    #    which prints `dui: window` rows, never `dui: tile=`).
    KERNEL_TILE=0
    grep -a -qF -- "dui: tile=" "$SER_B" && KERNEL_TILE=1
    # 3) The keyboard seam fanned the key out (kind 21) AND the WM stayed
    #    seated + pacing through the whole run (present markers ride on the
    #    long dwells — a live WM, not a corpse).
    KEYFAN=0; PRESENT=0
    grep -a -qE -- "key_fan=[1-9][0-9]*" "$SER_B" && KEYFAN=1
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    # 4) The window's rect CHANGED to the tiled master rect (24,0,837,700)
    #    — the WM's SET_WINDOW landed. (The `dui` registry row prints
    #    `rect=24,0,837,700` for the tiled window.)
    RECT=0
    grep -a -qE -- "rect=24,0,837,700" "$SER_B" && RECT=1
    if [ "$WM_TILE" = 1 ] && [ "$KERNEL_TILE" = 0 ] && [ "$KEYFAN" = 1 ] && [ "$PRESENT" = 1 ] && [ "$RECT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS5 Gate 2 live report ---"
    echo "boot A (registered-WM W1–W16 matrix):"
    echo "  runner rc=$RC_A  seated=$REG  present=$PRESENT  tile=$TILE  master=$MASTER  min=$MIN  restore=$REST  max=$MAX  ws=$WS  key_fan_row=$KEYFAN"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (WM-driven Ctrl+T policy):"
    echo "  runner rc=$RC_B  wm_tile=$WM_TILE  kernel_tile=$KERNEL_TILE  key_fan=$KEYFAN  wm_present=$PRESENT  tiled_rect=$RECT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wnd5-gate2: PASS — the W1–W16 matrix re-runs green with the WM registered AND a WM-driven Ctrl+T tiles the window (the kernel did not decide)"
    else
        echo "verify-live-wnd5-gate2: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the WM markers]" >> "$REPORT"
    grep -a "wnd: " "$SER_A" | head -4 >> "$REPORT" || true
    echo "[serial A: the dui matrix rows]" >> "$REPORT"
    grep -a "dui" "$SER_A" | head -10 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the WM policy + counters]" >> "$REPORT"
    grep -a -E "wnd: (tile|registered|present)|wm: (ptr_fan|key_fan)|rect=24,0,837,700" "$SER_B" | head -10 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi
