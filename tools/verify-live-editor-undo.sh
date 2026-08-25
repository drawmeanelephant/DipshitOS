#!/usr/bin/env bash
#
# verify-live-editor-undo.sh -- M23 card E2 class-B gate: undo/redo
# on EDIT.BIN running on real VZ.
#
# Mechanism: boots the desktop, navigates to EDIT.BIN (manifest index 10),
# types three characters, Ctrl+Z to undo, Ctrl+Y to redo, asserting the
# serial markers prove the undo/redo ring works.
#
# Class B — Apple silicon + VZ only; boots a real VM.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-editor-undo-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-editor-undo-report.txt)"

echo "=== verify-live-editor-undo: M23 E2 — undo/redo on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-editor-undo
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script.txt" <<'EOF'
exec DESKTOP.BIN
EOF

cat > "$RUN_DIR/script2.txt" <<'EOF'
echo edit-undo-live-ok
EOF

# EDIT.BIN is manifest index 10: 10 down arrows + return.
# After "edit: ready", type "abc", then Ctrl+Z (undo), Ctrl+Y (redo).
CHORDS="down,down,down,down,down,down,down,down,down,down,return,a,b,c,ctrl-z,ctrl-y"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    rm -f "$RUN_DIR"/gpu-screen-*
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --input --screen "$RUN_DIR/gpu-screen-$tag" \
        --custom-virtio --via-virtio \
        --script "$RUN_DIR/script.txt" \
        --script2 "$RUN_DIR/script2.txt" \
        --script2-after "edit: redo" \
        --input-chords "$CHORDS" \
        --input-chords-after "desktop: menu ready" \
        --input-chords-delay 2.0 \
        --script-expect "edit-undo-live-ok" \
        --timeout 120 \
        > "$(art live-editor-undo-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-editor-undo-serial-$tag.log)" || true
    local SER="$(art live-editor-undo-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 EDIT_READY=0 UNDO=0 REDO=0 DONE=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "edit: ready" "$SER" && EDIT_READY=1
        grep -qF -- "edit: undo" "$SER" && UNDO=1
        grep -qF -- "edit: redo" "$SER" && REDO=1
        grep -qF -- "edit-undo-live-ok" "$SER" && DONE=1
    fi
    { echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY undo=$UNDO redo=$REDO done=$DONE"; } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY undo=$UNDO redo=$REDO done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$EDIT_READY" = 1 ] && [ "$UNDO" = 1 ] && [ "$REDO" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-editor-undo gate (M23 E2) — undo/redo on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-editor-undo boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-editor-undo: PASS — undo/redo observed via serial markers ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-editor-undo: FAILED — $PASS/$BOOTS boot(s) passed; see $REPORT"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
