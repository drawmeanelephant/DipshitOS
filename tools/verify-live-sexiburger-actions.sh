#!/usr/bin/env bash
#
# verify-live-sexiburger-actions.sh — Milestone 19 Sexiburger Action Registry & Tab Model
# Live Class-B gate (issues #677, #701, #705, #782).
#
# Proves:
#   1. SEXITEST.BIN registers a command ("Sexitest Action", verb "test-act") into
#      Section 2 (Active app / Tomato layer) via the Action Registry IPC seam.
#   2. WND.BIN serves the registration and replies with an ack.
#   3. The registered command is invoked and executed end-to-end.
#   4. Window tab model: ATTACH_TAB, tab cycling, and DETACH_TAB.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-sexiburger-actions.sh
# Evidence: artifacts/live-sexiburger-actions-{run.txt,serial.log},
#           artifacts/live-sexiburger-actions-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sexiburger-actions-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sexiburger-actions-report.txt)"

echo "=== verify-live-sexiburger-actions: Milestone 19 Sexiburger Action Registry & Tab Model (issues #677, #701, #705, #782) ==="

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
gate_begin live-sexiburger-actions
gate_seed_share
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
        > "$(art live-sexiburger-actions-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-sexiburger-actions-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: WM + NOTEPAD + SEXITEST -----------------------------------------
echo "--- boot A: SEXITEST registers actions into Section 2 and exercises Tab Model ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'exec SEXITEST.BIN\necho sexitest-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\nwm\nsexiburger\necho sexitest-done\n' > "$RUN_DIR/s3-A.txt"

set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 6 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "sexitest: done" --script3-delay 8 \
    --script-expect "sexitest-done" --timeout 240
RC_A=$?
set -e

A_OK=0
A_REG=0
A_ACK=0
A_INV=0
A_EXEC=0
A_TAB_ATT=0
A_TAB_CYC=0
A_TAB_DET=0
A_MASCOT=0

SER_A="$(art live-sexiburger-actions-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1. Action registered in WM: section 2 (Active app / Tomato layer)
    grep -a -qF -- "wnd: action-registered section=2 label=Sexitest Action verb=test-act" "$SER_A" && A_REG=1
    # 2. Register ack received by app
    grep -a -qF -- "sexitest: register-ack applied=yes" "$SER_A" && A_ACK=1
    # 3. Action invoked in WM
    grep -a -qF -- "wnd: action-invoked label=Sexitest Action" "$SER_A" && A_INV=1
    # 4. Action executed in app
    grep -a -qF -- "sexitest: action executed: Sexitest Action ok=1" "$SER_A" && A_EXEC=1
    # 5. Tab attached
    grep -a -qF -- "wnd: tab-attach" "$SER_A" && grep -a -qF -- "sexitest: tab-attached ok=1" "$SER_A" && A_TAB_ATT=1
    # 6. Tab cycled
    grep -a -qF -- "wnd: tab-cycle" "$SER_A" && grep -a -qF -- "sexitest: tab-cycled ok=1" "$SER_A" && A_TAB_CYC=1
    # 7. Tab detached
    grep -a -qF -- "wnd: tab-detach" "$SER_A" && grep -a -qF -- "sexitest: tab-detached ok=1" "$SER_A" && A_TAB_DET=1
    # 8. Mascot monitor command executed
    grep -a -qF -- "SEXIBURGER ONLINE" "$SER_A" && A_MASCOT=1

    if [ "$A_REG" = 1 ] && [ "$A_ACK" = 1 ] && [ "$A_INV" = 1 ] && [ "$A_EXEC" = 1 ] && [ "$A_TAB_ATT" = 1 ] && [ "$A_TAB_CYC" = 1 ] && [ "$A_TAB_DET" = 1 ] && [ "$A_MASCOT" = 1 ]; then
        A_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- Milestone 19 Sexiburger Action Registry & Tab Model Report ---"
    echo "  runner rc=$RC_A"
    echo "  action_reg=$A_REG  reg_ack=$A_ACK  action_inv=$A_INV  action_exec=$A_EXEC"
    echo "  tab_attach=$A_TAB_ATT  tab_cycle=$A_TAB_CYC  tab_detach=$A_TAB_DET"
    echo "  mascot_cmd=$A_MASCOT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ]; then
        echo "verify-live-sexiburger-actions: PASS — Action Registry seam (S1/S5) and Tab Model (S6) verified end-to-end on live VZ"
    else
        echo "verify-live-sexiburger-actions: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps ----------------------------------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial proof]" >> "$REPORT"
    grep -a -E "wnd: action|sexitest:|wnd: tab|SEXIBURGER ONLINE|tentacles: 6" "$SER_A" | head -20 >> "$REPORT" || true
fi

[ "$A_OK" = 1 ] && exit 0 || exit 1
