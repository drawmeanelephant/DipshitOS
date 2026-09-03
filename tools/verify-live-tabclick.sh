#!/usr/bin/env bash
#
# verify-live-tabclick.sh — M37 DQ3 tab mouse interaction live proof (issue #839)
#
# TABHOLD.BIN self-drives to the held state (NOTEPAD visible+focused,
# TABHOLD attached-but-hidden; NOTEPAD at (56,56) 512x384, strip rows
# 72..93, cells 256px: cell0 56..311, cell1 312..567, × boxes 12px at
# each cell's right end). Three headless boots, one assertion each:
#   A. click cell1 body (440,82) → `wnd: tab-activate id=3`.
#   B. click cell1 × (561,82) → `wnd: tab-detach child=3` and NO `wnd: tab-drag`.
#   C. drag cell1 → (440,200) → `wnd: tab-drag` + `wnd: tab-detach child=3`.
#
# Pointer steps ride the custom-virtio INPUT queue (`d`/`u` held-drag
# grammar, 2.5 s pacing); TABHOLD's `tabhold: done` (60 s after cycled)
# keeps each VM alive past the steps with zero script phases.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-tabclick.sh
# Evidence: artifacts/live-tabclick-{run.txt,serial.log}-?,
#           artifacts/live-tabclick-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-tabclick-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-tabclick-report.txt)"

echo "=== verify-live-tabclick: M37 DQ3 tab mouse interaction (issue #839) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/wnd.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-tabclick
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    # Claim 6392 (issue #839): each boot starts from a clean window slate —
    # boot A's M21 W11 WINDOWS.SAV must not leak into boots B/C sharing this
    # share (restore would shift TABHOLD's id and fill window slots).
    gate_reset_share_state
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        "$@" \
        > "$(art live-tabclick-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-tabclick-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

printf 'wnd start\nexec NOTEPAD.BIN\nexec TABHOLD.BIN\n' > "$RUN_DIR/script-A.txt"

A_ACT=0
B_DET=0
B_NODRAG=0
C_DRAG=0
C_DET=0

# --- boot A: click cell body → activate --------------------------------------
echo "--- boot A: click tab cell → activate ---"
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --pointer-virtio "440,82,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240
RC_A=$?
set -e
SER_A="$(art live-tabclick-serial-A.log)"
# NOTE (issue #843): the markers below print synchronously AFTER their
# syscalls return, so a marker in the log PROVES the dispatch applied —
# even when the session-wide infra abort later kills the run (rc=1).
# rc is reported, not required.
if [ -f "$SER_A" ]; then
    grep -a -qF -- "wnd: tab-activate id=3" "$SER_A" && A_ACT=1
fi

# --- boot B: click × → detach, no drag --------------------------------------
echo "--- boot B: click tab × → detach ---"
set +e
run_boot B \
    --script "$RUN_DIR/script-A.txt" \
    --pointer-virtio "561,82,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240
RC_B=$?
set -e
SER_B="$(art live-tabclick-serial-B.log)"
if [ -f "$SER_B" ]; then
    grep -a -qF -- "wnd: tab-detach child=3" "$SER_B" && B_DET=1
    grep -a -qF -- "wnd: tab-drag" "$SER_B" || B_NODRAG=1
fi

# --- boot C: drag out → detach at drop --------------------------------------
echo "--- boot C: drag tab out → detach ---"
set +e
run_boot C \
    --script "$RUN_DIR/script-A.txt" \
    --pointer-virtio "440,82,d;440,200,u" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240
RC_C=$?
set -e
SER_C="$(art live-tabclick-serial-C.log)"
if [ -f "$SER_C" ]; then
    grep -a -qF -- "wnd: tab-drag" "$SER_C" && C_DRAG=1
    grep -a -qF -- "wnd: tab-detach child=3" "$SER_C" && C_DET=1
fi

# --- report ------------------------------------------------------------------
{
    echo "--- M37 DQ3 tab mouse interaction report ---"
    echo "  boot A (click→activate): rc=$RC_A activate=$A_ACT"
    echo "  boot B (×→detach): rc=$RC_B detach=$B_DET nodrag=$B_NODRAG"
    echo "  boot C (drag→detach): rc=$RC_C drag=$C_DRAG detach=$C_DET"
    if [ "$A_ACT" = 1 ] && [ "$B_DET" = 1 ] && [ "$B_NODRAG" = 1 ] && [ "$C_DRAG" = 1 ] && [ "$C_DET" = 1 ]; then
        echo "  RESULT: PASS"
    else
        echo "  RESULT: FAIL"
    fi
    echo "---"
} | tee "$REPORT"

if [ "$A_ACT" = 1 ] && [ "$B_DET" = 1 ] && [ "$B_NODRAG" = 1 ] && [ "$C_DRAG" = 1 ] && [ "$C_DET" = 1 ]; then
    echo "verify-live-tabclick: PASS — click switches, × detaches, drag detaches at drop, live on VZ"
    exit 0
else
    echo "verify-live-tabclick: FAIL"
    exit 1
fi
