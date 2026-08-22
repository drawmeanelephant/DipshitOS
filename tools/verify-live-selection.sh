#!/usr/bin/env bash
#
# verify-live-selection.sh -- milestone-eighteen card T2 class-B gate (issue #405):
# scrollback text selection, copy, and paste on real VZ.
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --script2 / --script-expect, claim-6684). Phase 1
# (--script) fills the scrollback with echo lines. Phase 2 types PageUp and
# Up through the SYNTHESIZED KEYBOARD as NSEvents (--input-chords, claims
# 1809 + 5093) — the real scroll keys enter selection and extend the range.
# Phase 3 (--script2, --script2-delay after the marker so it lands AFTER
# the chords finish) sends the Ctrl chords over serial as literal bytes —
# Ctrl+C to copy and Ctrl+V to paste — because VZ's synthesized keyboard
# cannot deliver modifier chords (activation wall, hardware contract). The
# shell's own `input` report then proves both keyboard chords reached the
# guest keymap (events=2 dropped=0).
#
# The walk:
#   echo line-01 … echo line-20           -> fill scrollback
#   echo fill-ready                       -> phase-1 marker
#   PageUp (KEYBOARD chord)               -> enter selection mode
#   Up     (KEYBOARD chord)               -> extend selection
#   Ctrl+C (serial)                       -> copy to clipboard ("copied")
#   echo                                   -> empty submit (new prompt)
#   Ctrl+V (serial) Enter                 -> paste clipboard contents
#   input (serial)                        -> report: events=2 dropped=0
#                                            (the two keyboard chords)
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

# --- phase 2: REAL scroll keys through the synthesized keyboard --------------
# Claim 5093: macChord gained pageup (kVK 0x74) and `up` was already there;
# the guest keymap decodes 0x4b -> ESC [ 5 ~ and 0x52 -> ESC [ A. PageUp
# enters selection, Up extends the range by one line.
# 2 chords x keyDown+keyUp at 2.0s/event = 8s of typing after boot.
CHORDS="pageup,up"

# --- phase 3: Ctrl chords over serial (modifier wall — cannot be typed) ------
# VZ's synthesized keyboard cannot deliver modifier chords (activation
# wall, hardware contract), so Ctrl+C (copy) and Ctrl+V (paste) are fed
# over the serial attachment as literal bytes — the SAME shell code paths
# (verify-live-editing pattern). --script2-delay 12 parks the burst until
# after the two keyboard chords have landed (done at ~9s post-marker).
# After the paste, `input` reports events=2 dropped=0 — the keyboard proof.
printf '\003echo \n\026\ninput\necho selection-live-ok\n' > artifacts/live-selection-keys.txt

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script "$SCRIPT" \
        --input-chords "$CHORDS" --input-chords-after "fill-ready" \
        --input-chords-delay 2.0 \
        --script2 artifacts/live-selection-keys.txt --script2-after "fill-ready" --script2-delay 12 \
        --script-expect "selection-live-ok" \
        --timeout 60 \
        > "artifacts/live-selection-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-selection-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 FILL_READY=0 COPIED=0 PASTED=0 INREPORT=0 DONE=0 RUNNERFLAG=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "fill-ready" artifacts/vm-serial.log && FILL_READY=1
        grep -qF -- "copied" artifacts/vm-serial.log && COPIED=1
        # The paste proof: the clipboard's first selected line is fed into
        # the editor and submitted (observed live as "unknown command
        # 'line-16'"). The line number depends on scrollback capture, so
        # match the line-1x shape.
        grep -qE -- "unknown command 'line-1[0-9]'" artifacts/vm-serial.log && PASTED=1
        grep -qF -- "input: armed=1 fifo=0/64 dropped=0 events=2" artifacts/vm-serial.log && INREPORT=1
        grep -qF -- "selection-live-ok" artifacts/vm-serial.log && DONE=1
    fi
    grep -a -qF -- "input-chords: ENABLED" "artifacts/live-selection-run-$tag.txt" && RUNNERFLAG=1
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY copied=$COPIED pasted=$PASTED report=$INREPORT done=$DONE runner-flag=$RUNNERFLAG"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER fill-ready=$FILL_READY copied=$COPIED pasted=$PASTED report=$INREPORT done=$DONE runner-flag=$RUNNERFLAG"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILL_READY" = 1 ] && [ "$COPIED" = 1 ] && [ "$PASTED" = 1 ] && [ "$INREPORT" = 1 ] && [ "$DONE" = 1 ] && [ "$RUNNERFLAG" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-selection gate (M18 T2, issue #405) — scrollback selection + copy/paste on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: 20 echo lines + fill-ready marker"
    echo "phase 2: keyboard chords PageUp + Up (real scroll keys)"
    echo "phase 3: serial Ctrl+C (copy), echo, Ctrl+V (paste), input report (events=2), selection-live-ok"
    echo "assertions: banner, fill marker, copied, pasted (clipboard line submitted), input report events=2 dropped=0, done, runner input-chords flag"
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
