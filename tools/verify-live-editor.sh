#!/usr/bin/env bash
#
# verify-live-editor.sh -- M23 E2-E5 class-B gate:
# undo/redo, goto-line, multi-file tabs on real VZ hardware.
#
# Mechanism: boots the production image, execs EDIT.BIN from the monitor,
# waits for the app to be ready, sends Ctrl chords to exercise the new
# features, and asserts the serial markers prove they happened.
#
# The walk:
#   exec EDIT.BIN                          -> launch editor
#   (wait for edit: ready)                  -> app event loop running
#   Ctrl+T                                  -> open new tab (E4)
#   (assert edit: tab-open)                -> tab created
#   Ctrl+Z                                  -> undo (E2)
#   (assert edit: undo)                    -> undo happened
#   Ctrl+G                                  -> open goto prompt (E3)
#   (assert edit: goto-open)               -> goto prompt opened
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-editor.sh
#
# Evidence saved under artifacts/: live-editor-gate.txt,
# live-editor-report.txt, live-editor-run.txt, live-editor-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-editor-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-editor-report.txt)"

echo "=== verify-live-editor: M23 E2-E5 — undo, goto, tabs on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-editor
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# --- phase 1: launch EDIT.BIN from the monitor ------------------------------
cat > "$SCRIPT" <<'EOF'
exec EDIT.BIN
EOF

# --- phase 2: Ctrl+T (new tab), Ctrl+Z (undo), Ctrl+G (goto) ----------------
# Ctrl+T = ctrl-t, Ctrl+Z = ctrl-z, Ctrl+G = ctrl-g (the runner maps
# ctrl-a..ctrl-z to macOS keycodes via --input-chords)
INPUT_CHORDS="ctrl-t,ctrl-z,ctrl-g"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --input-chords "$INPUT_CHORDS" \
        --input-chords-after "edit: ready" \
        --script-expect "edit: goto-open" \
        --timeout 45 \
        > "$(art live-editor-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-editor-serial-$tag.log)" || true
    local SER="$(art live-editor-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 EDIT_READY=0 TAB_OPEN=0 UNDO=0 GOTO_OPEN=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "edit: ready" "$SER" && EDIT_READY=1
        grep -qF -- "edit: tab-open" "$SER" && TAB_OPEN=1
        grep -qF -- "edit: undo" "$SER" && UNDO=1
        grep -qF -- "edit: goto-open" "$SER" && GOTO_OPEN=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY tab-open=$TAB_OPEN undo=$UNDO goto-open=$GOTO_OPEN"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY tab-open=$TAB_OPEN undo=$UNDO goto-open=$GOTO_OPEN"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$EDIT_READY" = 1 ] && \
    [ "$TAB_OPEN" = 1 ] && [ "$UNDO" = 1 ] && [ "$GOTO_OPEN" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-editor gate (M23 E2-E5) — undo, goto, tabs on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: exec EDIT.BIN from monitor"
    echo "phase 2: Ctrl+T (new tab), Ctrl+Z (undo), Ctrl+G (goto) via input-chords"
    echo "assertions: edit: ready, edit: tab-open, edit: undo, edit: goto-open"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-editor boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-editor: PASS — undo (Ctrl+Z), goto-line (Ctrl+G), multi-file tabs (Ctrl+T) serial markers observed ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-editor: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-editor-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
