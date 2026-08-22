#!/usr/bin/env bash
#
# verify-live-search.sh -- milestone-eighteen card T3 class-B gate (issue #406):
# reverse-i-search (Ctrl+R) on real VZ.
#
# Mechanism: boots the production image with scripted input: phase 1 submits
# distinctive commands to history. Phase 2 sends ONLY the Ctrl+R entry over
# serial (a modifier chord — VZ's synthesized keyboard cannot deliver it,
# activation wall, hardware contract). Phase 3 types the QUERY and the
# Enter-accept through the synthesized keyboard (--input-chords, claims
# 1809 + 5093): the search bar itself re-prints with the growing query and
# its match on every chord, so the serial log proves the keyboard-typed
# query found the right history line. The keyboard Return decodes to LF,
# which search mode accepts like CR (T3 live-gate fix).
#
# The walk:
#   echo build-up-*            -> fill history with noise commands
#   echo special-search-target-777 -> the target command we'll search for
#   echo fill-ready            -> phase-1 marker
#   Ctrl+R (serial)            -> enter reverse-i-search
#   s p e c i a l (KEYBOARD)   -> query grows; bar shows the match
#   Return (KEYBOARD)          -> accept; matched line sits at the prompt
#   echo search-live-ok Return (KEYBOARD) -> appends to the matched line;
#                                the submit runs both (output shows both)
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

# --- phase 2: Ctrl+R entry over serial (modifier wall — cannot be typed) -----
# The ONLY serial byte of the walk: entering search mode. The query and the
# accept come through the keyboard in phase 3.
printf '\022' > artifacts/live-search-keys.txt

# --- phase 3: query + accept through the synthesized keyboard ----------------
# Claim 5093: the guest keymap decodes letter chords and the Return key
# (0x28 -> LF). Search mode accepts LF like CR (T3 gate fix). Every query
# chord re-prints the search bar with the match, so the log proves the
# keyboard-typed query matched the right line. After the accept, the marker
# echo appends to the accepted line and the submit runs both (both strings
# appear in the output) — the accept + submit proof.
# 28 chords x keyDown+keyUp at 2.0s/event = 112s of typing after boot.
CHORDS="s,p,e,c,i,a,l,return,e,c,h,o,space,s,e,a,r,c,h,-,l,i,v,e,-,o,k,return"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script "$SCRIPT" \
        --input-chords "$CHORDS" --input-chords-after "fill-ready" \
        --input-chords-delay 2.0 \
        --script2 artifacts/live-search-keys.txt --script2-after "fill-ready" \
        --script-expect "search-live-ok" \
        --timeout 240 \
        > "artifacts/live-search-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-search-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 SEARCH=0 MATCH=0 DONE=0 RUNNERFLAG=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "fill-ready" artifacts/vm-serial.log && FILL_READY=1
        # Search mode entered and redrew its bar (the Ctrl+R landed).
        grep -qF -- '(reverse-i-search)`' artifacts/vm-serial.log && SEARCH=1
        # The KEYBOARD-typed query produced the full-match bar line — this
        # text can only come from the search bar with query "special" and
        # the right match (proves the chords reached the keymap and search).
        grep -qF -- '(reverse-i-search)`special`: echo special-search-target-777' artifacts/vm-serial.log && MATCH=1
        # The accepted line + appended marker submitted and ran (accept proof).
        grep -qF -- "search-live-ok" artifacts/vm-serial.log && DONE=1
    fi
    grep -a -qF -- "input-chords: ENABLED" "artifacts/live-search-run-$tag.txt" && RUNNERFLAG=1
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY search=$SEARCH match=$MATCH done=$DONE runner-flag=$RUNNERFLAG"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY search=$SEARCH match=$MATCH done=$DONE runner-flag=$RUNNERFLAG"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$SEARCH" = 1 ] && [ "$MATCH" = 1 ] && [ "$DONE" = 1 ] && [ "$RUNNERFLAG" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-search gate (M18 T3, issue #406) — reverse-i-search on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: submit distinctive commands to history"
    echo "phase 2: Ctrl+R entry over serial (modifier wall)"
    echo "phase 3: keyboard chords type the query + Return accept, then the marker echo"
    echo "assertions: banner, fill marker, search bar shown, full-match bar line from keyboard-typed query, done, runner input-chords flag"
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
