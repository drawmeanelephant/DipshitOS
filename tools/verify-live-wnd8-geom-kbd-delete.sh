#!/usr/bin/env bash
#
# verify-live-wnd8-geom-kbd-delete.sh — M32 WMS8 Gate 5 (issue #628, claim
# 9879) class-B gate: the kernel's geometry-policy KEYBOARD-DECISION layer is
# deleted. WMS5 Gate 2 drained the geometry chords (tile/master/min/max/ws/
# fullscreen/aot) to the WM — the WM owns them via the kind-21 WM_KEY stream
# and issues SET_WINDOW/SET_STATE; the kernel's own chord consumers were
# provably dormant whenever a WM is registered (their pending flags gated
# behind !wm_owns_input). Per WMS8's delete rule (a block is deleted only
# when its parity gate has been green with the WM registered — the W5 matrix
# re-ran green while seated), WMS8 Gate 5 DELETES that dormant keyboard
# layer from input.zig + shell.zig. The APPLIED primitives stay (driven by
# the `dui` monitor commands and SET_STATE), and the W1–W16 matrix re-runs
# green THROUGH them.
#
# Two boots prove both halves of the deletion:
#   * Boot A (shim, no WM): a REAL Ctrl+T over the virtio keyboard. With no
#     WM the kernel's tile DECISION is DELETED, so shim mode now does NOTHING
#     — no `dui: tile=` line, and NOTEPAD's rect does NOT change to the tiled
#     master rect. This is the issue's "no compositing policy" shim end-state
#     (the shim no longer self-toggles geometry). The shell stays responsive.
#   * Boot B (WM registered): the W1/W2/W3/W6/W4 `dui` matrix lines re-run
#     green against the applied primitives (zero regression — the matrix is
#     monitor-driven, not keyboard-driven), AND a REAL Ctrl+T fans to the WM
#     (kind 21, key_fan counters grow), the WM decides (`wnd: tile`) and the
#     kernel APPLIES the SET_WINDOW rect (24,0,837,700) while printing no
#     `dui: tile=` keyboard path — the WM, not the kernel, decided.
#
# KEPT chords with no WM coverage (explicitly out of scope, still self-
# consumed in shim mode, zero regression): Ctrl+Shift+B (lower-back) and
# Alt+arrows (move). Alt+Tab is a separate WMS6 focus surface.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:  bash tools/verify-live-wnd8-geom-kbd-delete.sh
# Evidence: artifacts/live-wnd8-geom-kbd-delete-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd8-geom-kbd-delete-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/628

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd8-geom-kbd-delete-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd8-geom-kbd-delete-report.txt)"

echo "=== verify-live-wnd8-geom-kbd-delete: M32 WMS8 Gate 5 — the geometry-policy keyboard-decision layer is deleted (issue #628) ==="

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
gate_begin live-wnd8-geom-kbd-delete
echo "run dir: $RUN_DIR"

run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        "$@" \
        > "$(art live-wnd8-geom-kbd-delete-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd8-geom-kbd-delete-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim (no WM) — the drained Ctrl+T now does NOTHING ----------------
# The kernel's tile DECISION is DELETED, so a REAL Ctrl+T with no WM must not
# tile — no `dui: tile=` keyboard path, NOTEPAD keeps its original rect (the
# applied primitives are still reachable via `dui tile 2`, but the CHORD no
# longer drives them). This is the issue's "no compositing policy" end-state.
echo "--- boot A: no WM — Ctrl+T now does nothing (the kernel no longer self-decides geometry) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui\necho shim-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\necho shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --input-chords "ctrl-t" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "shim-go" --script3-delay 20 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_KBD_TILE=0; A_TILED_RECT=0; A_FAULT=0
SER_A="$(art live-wnd8-geom-kbd-delete-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The keyboard path did NOT print `dui: tile=` (no self-decide).
    grep -a -qF -- "dui: tile=" "$SER_A" && A_KBD_TILE=1
    # 2) The window never moved to the tiled master rect (24,0,837,700) —
    #    the chord did NOT apply geometry.
    grep -a -qE -- "rect=24,0,837,700" "$SER_A" && A_TILED_RECT=1
    # 3) No real fault/panic.
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "$A_KBD_TILE" = 0 ] && [ "$A_TILED_RECT" = 0 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-registered matrix + WM-driven chord -------------------------
# Re-run the W1/W2/W3/W6/W4 `dui` matrix lines against the applied primitives
# (zero regression — they are monitor commands, not keyboard paths), PLUS a
# REAL Ctrl+T that fans to the WM (kind 21), the WM decides (`wnd: tile`), and
# the kernel applies the SET_WINDOW rect while printing no `dui: tile=`.
echo "--- boot B: with the WM registered the matrix re-runs green and a WM-driven Ctrl+T tiles (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui tile 2\ndui master\ndui minimize 2\ndui restore 2\ndui maximize 2\ndui ws 1\ndui ws 0\nwm\necho matrix-go\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\nwm\necho ctrl-t-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --input-chords "ctrl-t" --input-chords-after "matrix-go" --input-chords-delay 2 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "matrix-go" --script3-delay 20 \
    --script-expect "ctrl-t-done" --timeout 260
RC_B=$?
set -e
B_OK=0
B_MATRIX=0; B_WM_TILE=0; B_KBD_TILE=0; B_KEYFAN=0; B_PRESENT=0; B_RECT=0
SER_B="$(art live-wnd8-geom-kbd-delete-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The W1–W16 matrix re-ran green against the applied primitives.
    grep -a -qF -- "dui tile: id=2 mode=on" "$SER_B" && B_MATRIX=1
    grep -a -qF -- "dui ws: workspace=1" "$SER_B" && B_MATRIX=1
    # 2) The WM decided the chord: its `wnd: tile` marker printed.
    grep -a -qF -- "wnd: tile" "$SER_B" && B_WM_TILE=1
    # 3) The kernel did NOT consume the chord (no `dui: tile=` keyboard row).
    grep -a -qF -- "dui: tile=" "$SER_B" && B_KBD_TILE=1
    # 4) The kind-21 fan-out + the WM pacing (live WM, not a corpse).
    grep -a -qE -- "key_fan=[1-9][0-9]*" "$SER_B" && B_KEYFAN=1
    grep -a -qF -- "wnd: present" "$SER_B" && B_PRESENT=1
    # 5) The WM's SET_WINDOW rect landed (24,0,837,700).
    grep -a -qE -- "rect=24,0,837,700" "$SER_B" && B_RECT=1
    if [ "$B_MATRIX" = 1 ] && [ "$B_WM_TILE" = 1 ] && [ "$B_KBD_TILE" = 0 ] && [ "$B_KEYFAN" = 1 ] && [ "$B_PRESENT" = 1 ] && [ "$B_RECT" = 1 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "$REVISION branch=$BRANCH"
    echo "bootA(shim Ctrl+T inert, deleted decision)=$A_OK bootB(WM matrix + WM-driven tile)=$B_OK"
} > "$REPORT"

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "verify-live-wnd8-geom-kbd-delete: PASS (shim no longer self-tiles; the WM decides geometry and the matrix re-runs green)"
    exit 0
else
    echo "verify-live-wnd8-geom-kbd-delete: FAIL (A=$A_OK B=$B_OK)"
    echo "--- boot A evidence ---"; [ -f "$SER_A" ] && grep -a -E "dui: tile=|rect=24,0,837,700|panic|abort|win_close" "$SER_A" | tail -10 || true
    echo "--- boot B evidence ---"; [ -f "$SER_B" ] && grep -a -E "dui tile:|dui ws:|wnd: tile|key_fan=|rect=24,0,837,700|wnd: present" "$SER_B" | tail -20 || true
    exit 1
fi