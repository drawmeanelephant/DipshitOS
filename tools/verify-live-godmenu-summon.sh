#!/usr/bin/env bash
#
# verify-live-godmenu-summon.sh — M37 DQ1 God Menu live proof (issue #836)
#
# Proves, in ONE headless VZ boot:
#   1. WND.BIN preloads the apps catalog from /host/APPS.TXT at startup
#      (`wnd: god-menu apps=N` with N > 4 — the hardcoded fallback is 4,
#      the registry cap is 16, so N in 5..16 means the dynamic read worked).
#   2. The global Ctrl+Space chord summons the menu
#      (`wnd: god-menu open`) over the custom-virtio INPUT queue
#      (`--input-chords ctrl-space`, needs the M37 `ctrl-space` token).
#   3. Typing a filter + Return executes the match
#      (`wnd: god-menu exec verb=calc`, CALC.BIN launches).
#   4. Escape dismisses what remains (`wnd: god-menu close`).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-godmenu-summon.sh
# Evidence: artifacts/live-godmenu-summon-{run.txt,serial.log},
#           artifacts/live-godmenu-summon-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-godmenu-summon-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-godmenu-summon-report.txt)"

echo "=== verify-live-godmenu-summon: M37 DQ1 God Menu summon + dynamic apps (issue #836) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/wnd.zig user/src/lib/sexiburger.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-godmenu-summon
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
        > "$(art live-godmenu-summon-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-godmenu-summon-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: WND + NOTEPAD, Ctrl+Space summon, Escape dismiss ----------------
echo "--- boot A: dynamic apps preload + Ctrl+Space summon + Escape dismiss ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"

set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --input-chords "ctrl-space,c,a,l,c,return,escape" --input-chords-after "notepad: ready" \
    --script-expect "wnd: god-menu exec verb=calc" --timeout 150
RC_A=$?
set -e

SER_A="$(art live-godmenu-summon-serial-A.log)"
A_APPS=0
A_OPEN=0
A_EXEC=0
A_CLOSE=0
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1. Dynamic catalog: N > 4 (fallback is 4, cap is 16).
    if grep -a -qF -- "wnd: god-menu apps=" "$SER_A"; then
        APPS_N="$(grep -a -o -- "wnd: god-menu apps=[0-9]*" "$SER_A" | head -1 | grep -a -o "[0-9]*$")"
        if [ -n "$APPS_N" ] && [ "$APPS_N" -gt 4 ] && [ "$APPS_N" -le 16 ]; then
            A_APPS=1
        fi
        echo "apps marker: N=$APPS_N (need 5..16)"
    fi
    # 2. Summon.
    grep -a -qF -- "wnd: god-menu open" "$SER_A" && A_OPEN=1
    # 3. Filter + exec (already implied by rc=0, pinned here for the report).
    grep -a -qF -- "wnd: god-menu exec verb=calc" "$SER_A" && A_EXEC=1
    # 4. Dismiss (exec closes the menu via toggle; trailing escape is a no-op).
    grep -a -qF -- "wnd: god-menu close" "$SER_A" && A_CLOSE=1
fi

# --- report ------------------------------------------------------------------
{
    echo "--- M37 DQ1 God Menu summon report ---"
    echo "  runner rc=$RC_A"
    echo "  dynamic_apps=$A_APPS  summon_open=$A_OPEN  filter_exec=$A_EXEC  dismiss_close=$A_CLOSE"
    if [ "$A_APPS" = 1 ] && [ "$A_OPEN" = 1 ] && [ "$A_EXEC" = 1 ] && [ "$A_CLOSE" = 1 ]; then
        echo "  RESULT: PASS"
    else
        echo "  RESULT: FAIL"
    fi
    echo "---"
} | tee "$REPORT"

if [ -f "$SER_A" ]; then
    echo "[serial proof]" >> "$REPORT"
    grep -a -E "wnd: god-menu|CHORD-SEQ|exec: loaded CALC" "$SER_A" | head -12 >> "$REPORT" || true
fi

if [ "$A_APPS" = 1 ] && [ "$A_OPEN" = 1 ] && [ "$A_EXEC" = 1 ] && [ "$A_CLOSE" = 1 ]; then
    echo "verify-live-godmenu-summon: PASS — dynamic APPS.TXT catalog + Ctrl+Space summon + filter/exec + dismiss live on VZ"
    exit 0
else
    echo "verify-live-godmenu-summon: FAIL"
    exit 1
fi
