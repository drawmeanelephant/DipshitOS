#!/usr/bin/env bash
#
# verify-live-history.sh -- milestone-eighteen card T4 class-B gate (issue #407):
# persistent command history saved to HISTORY.TXT on FAT, loaded on boot.
#
# Mechanism: boots the production image, types distinctive commands to
# build history, reboots (new VM session), and verifies the Up arrow
# recalls the most recent command from the persisted file. The Up arrow
# and Enter are typed through the SYNTHESIZED KEYBOARD as NSEvents
# (--input-chords, claims 1809 + 5093); only the success-marker echo
# stays serial (delayed past the chords).
#
# The walk:
#   Boot 1: type commands, then shutdown signal
#     echo T4-first-command
#     echo T4-second-unique
#     echo T4-third-marker
#     echo history-live-ready   -> marker for phase completion
#   Boot 2: verify history survived reboot
#     Up arrow (KEYBOARD)       -> recalls "echo T4-third-marker"
#     Enter (serial \r)         -> re-executes, output proves recall
#     input (serial)            -> report: events=1 kb-usage=0x52 (the chord)
#     echo history-live-ok      -> success marker
#
# Class B — Apple silicon + VZ only. Two boots required.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-history-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-history-report.txt"

echo "=== verify-live-history: M18 T4 — persistent history on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- boot 1: build history --------------------------------------------------
# The LAST command is what a single Up arrow recalls after the newest-first
# restore (editor history index 0 = most recent), so T4-third-marker must be
# last. The runner exits as soon as script-expect matches, so the expect is
# the LAST line's own marker (its echo) — the whole burst (including the
# HISTORY.TXT save) completes within the runner's next poll.
SCRIPT1="artifacts/live-history-script1.txt"
cat > "$SCRIPT1" <<'EOF'
echo T4-first-command
echo T4-second-unique
echo history-live-ready
echo T4-third-marker
EOF

# boot 2 needs --script to enter the runner's script mode (script2 and
# script-expect only take effect there), but must not type anything that
# pollutes the top of the recalled history — an empty script file.
: > artifacts/live-history-empty.txt

# --- boot 2: verify recall ---------------------------------------------------
# The Up arrow goes through the SYNTHESIZED KEYBOARD as an NSEvent
# (--input-chords, claims 1809 + 5093); the Enter that submits it stays
# serial (the original walk's \r). The serial burst (--script2-delay 15,
# parked past the single chord which lands ~2s after the first prompt)
# submits the recalled line, runs `input` — whose report proves the chord
# decoded exactly once (events=1 kb-usage=0x52) — then prints the success
# marker. The recall output only appears if the chord really landed
# (history is not printed at load, so the string is otherwise absent
# from boot 2).
printf '\rinput\recho history-live-ok\r' > artifacts/live-history-keys.txt
CHORDS="up"

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    # Boot 1: build history
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-expect "T4-third-marker" --timeout 30 \
        > "artifacts/live-history-run-$tag-boot1.txt" 2>&1
    local RC1=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-history-serial-$tag-boot1.log" || true

    if [ "$RC1" != 0 ]; then
        echo "$tag: boot1 failed rc=$RC1" | tee -a "$REPORT"
        return 1
    fi

    # Boot 2: verify history survived, recall via Up arrow (KEYBOARD)
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --input --display \
        --script artifacts/live-history-empty.txt \
        --input-chords "$CHORDS" --input-chords-after "dipshit> " \
        --input-chords-delay 2.0 \
        --script2 artifacts/live-history-keys.txt --script2-after "dipshit> " --script2-delay 15 \
        --script-expect "history-live-ok" \
        --timeout 60 \
        > "artifacts/live-history-run-$tag-boot2.txt" 2>&1
    local RC2=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-history-serial-$tag-boot2.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 MARKER=0 INREPORT=0 OK=0 RUNNERFLAG=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        # Only present if the keyboard Up chord recalled the persisted line
        # (history is not printed at load in boot 2).
        grep -qF -- "T4-third-marker" artifacts/vm-serial.log && MARKER=1
        # The shell's input report proves the Up chord decoded exactly once
        # (a lost chord would show events=0 and fail honestly).
        grep -qF -- "input: armed=1 fifo=0/64 dropped=0 events=1" artifacts/vm-serial.log && INREPORT=1
        grep -qF -- "history-live-ok" artifacts/vm-serial.log && OK=1
    fi
    grep -a -qF -- "input-chords: ENABLED" "artifacts/live-history-run-$tag-boot2.txt" && RUNNERFLAG=1
    {
        echo "$tag: rc1=$RC1 rc2=$RC2 serial-bytes=$SERIAL_BYTES banner=$BANNER marker=$MARKER report=$INREPORT ok=$OK runner-flag=$RUNNERFLAG"
    } >> "$REPORT"
    echo "$tag rc1=$RC1 rc2=$RC2 serial-bytes=$SERIAL_BYTES banner=$BANNER marker=$MARKER report=$INREPORT ok=$OK runner-flag=$RUNNERFLAG"
    [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ "$BANNER" = 1 ] && [ "$MARKER" = 1 ] && [ "$INREPORT" = 1 ] && [ "$OK" = 1 ] && [ "$RUNNERFLAG" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-history gate (M18 T4, issue #407) — persistent history on VZ"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "boot 1: build history with distinctive commands"
    echo "boot 2: keyboard Up chord recalls T4-third-marker; serial \r submits, input report (events=1), marker echo"
    echo "assertions: banner, recall marker, input report events=1, done, runner input-chords flag"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-history boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-history: PASS — persistent history survives reboot ($PASS/$BOOTS pair(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-history: FAILED — $PASS/$BOOTS pair(s) passed; see artifacts/live-history-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi