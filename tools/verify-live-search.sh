#!/usr/bin/env bash
#
# verify-live-search.sh -- milestone-eighteen card T3 class-B gate (issue #406):
# reverse-i-search (Ctrl+R) on real VZ.
#
# Mechanism: boots the production image with scripted keystrokes that submit
# a distinctive command to history, then use Ctrl+R to search for it, accept
# via Enter, and re-execute. Proves the match-accept pipeline works live.
#
# The walk:
#   echo THE-TARGET         -> (just output, recognizable string)
#   echo search-target-999  -> the target command we'll search for
#   Ctrl+R + "search-target" -> find the match, Enter accepts
#   Enter                   -> re-executes, output shows "search-target-999"
#   echo search-live-ok     -> success marker
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-search-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-search-report.txt"
SCRIPT="artifacts/live-search-script.txt"

echo "=== verify-live-search: M18 T3 — reverse-i-search on VZ, $BOOTS boot(s) ==="

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

# --- phase 1: fill history with a distinctive command -----------------------
cat > "$SCRIPT" <<'EOF'
echo build-up-1
echo build-up-2
echo special-search-target-777
echo build-up-4
echo build-up-5
echo fill-ready
EOF

# --- phase 2: Ctrl+R → type "special" → Enter (accept) → Enter (re-exec) ---
CTRL_R=$'\x12'
INPUT_STRING="${CTRL_R}special
echo search-live-ok
"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" \
        --input-string "$INPUT_STRING" \
        --input-string-after "fill-ready" \
        --script-expect "search-live-ok" \
        --timeout 40 \
        > "artifacts/live-search-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-search-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 MATCH_FOUND=0 DONE=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "fill-ready" artifacts/vm-serial.log && FILL_READY=1
        # The reverse-i-search should show the match line containing "special-search-target-777"
        grep -qF -- "special-search-target-777" artifacts/vm-serial.log && MATCH_FOUND=1
        grep -qF -- "search-live-ok" artifacts/vm-serial.log && DONE=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY match-found=$MATCH_FOUND done=$DONE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY match-found=$MATCH_FOUND done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$MATCH_FOUND" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-search gate (M18 T3, issue #406) — reverse-i-search on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: submit distinctive commands to history"
    echo "phase 2: Ctrl+R, type search query, Enter accept, Enter re-exec, marker"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-search boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-search: PASS — reverse-i-search finds matches in history, Enter accepts, shell survives ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-search: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-search-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi