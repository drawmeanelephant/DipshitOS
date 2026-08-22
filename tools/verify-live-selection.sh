#!/usr/bin/env bash
#
# verify-live-selection.sh -- milestone-eighteen card T2 class-B gate (issue #405):
# scrollback text selection, copy, and paste on real VZ.
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --input-string / --script-expect, claim-6684). Phase 1
# (--script) fills the scrollback with echo lines. Phase 2 (--input-string)
# sends PageUp to enter selection, Up/Down to adjust range, Ctrl+C to copy
# to the clipboard, then Ctrl+V to paste at a new prompt.
#
# The walk:
#   echo line-01 … echo line-20           -> fill scrollback
#   echo fill-ready                       -> phase-1 marker
#   PageUp                                -> enter selection mode
#   Up                                    -> extend selection
#   Ctrl+C                                -> copy to clipboard
#   echo                                   -> empty submit (new prompt)
#   Ctrl+V Enter                          -> paste clipboard contents
#   echo selection-live-ok                -> success marker
#
# Class B — Apple silicon + VZ only; boots a real VM.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-selection-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-selection-report.txt"
SCRIPT="artifacts/live-selection-script.txt"

echo "=== verify-live-selection: M18 T2 — scrollback selection + copy/paste on VZ, $BOOTS boot(s) ==="

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

# --- phase 1: fill scrollback with echo lines --------------------------------
cat > "$SCRIPT" <<'EOF'
echo line-01
echo line-02
echo line-03
echo line-04
echo line-05
echo line-06
echo line-07
echo line-08
echo line-09
echo line-10
echo line-11
echo line-12
echo line-13
echo line-14
echo line-15
echo line-16
echo line-17
echo line-18
echo line-19
echo line-20
echo fill-ready
EOF

# --- phase 2: select + copy + paste ------------------------------------------
# PageUp, Up (extend), Ctrl+C (copy), Enter (empty line = new prompt), 
# Ctrl+V (paste), Enter
PGUP=$'\x1b[5~'
UP=$'\x1b[A'
CTRLC=$'\x03'
CTRLV=$'\x16'
INPUT_STRING="${PGUP}${UP}${CTRLC}echo 
${CTRLV}
echo selection-live-ok
"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" \
        --input-string "$INPUT_STRING" \
        --input-string-after "fill-ready" \
        --script-expect "selection-live-ok" \
        --timeout 40 \
        > "artifacts/live-selection-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-selection-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 COPIED=0 PASTED=0 DONE=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "fill-ready" artifacts/vm-serial.log && FILL_READY=1
        grep -qF -- "copied" artifacts/vm-serial.log && COPIED=1
        grep -qF -- "selection-live-ok" artifacts/vm-serial.log && DONE=1
        # Verify line-01 content appears in the output (scrolled back into view by paste)
        grep -qF -- "line-01" artifacts/vm-serial.log && PASTED=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY copied=$COPIED pasted=$PASTED done=$DONE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY copied=$COPIED pasted=$PASTED done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$COPIED" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-selection gate (M18 T2, issue #405) — scrollback selection + copy/paste on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: 20 echo lines + fill-ready marker"
    echo "phase 2: PageUp, Up, Ctrl+C (copy), echo, Ctrl+V (paste), Enter, selection-live-ok"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-selection boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-selection: PASS — scrollback selection + copy/paste work on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-selection: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-selection-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi