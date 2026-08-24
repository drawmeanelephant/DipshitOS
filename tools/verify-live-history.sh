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
# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# scripts, EFI var store, and serial logs live under $RUN_DIR. This is a
# PERSISTENCE gate — boot 2 exists precisely to prove boot 1's HISTORY.TXT
# write SURVIVED on the same image — so both boots attach the CANONICAL
# artifacts/disk.img under tools/lib/gate-run.sh's gate_shared_disk_lock
# (the macOS 27.0 fresh-copy FAT-write defect makes private copies/
# overlays unusable here; observed claim 5069). Two concurrent instances
# serialize on the lock instead of corrupting the shared disk. Set
# DIPSHIT_GATE_SUFFIX=_alt for distinct canonical evidence names.
#
# Class B — Apple silicon + VZ only. Two boots required.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-history-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_shared_disk_unlock; gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-history-report.txt)"

echo "=== verify-live-history: M18 T4 — persistent history on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH pairs=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-history
echo "run dir: $RUN_DIR"

# --- boot 1: build history --------------------------------------------------
# The LAST command is what a single Up arrow recalls after the newest-first
# restore (editor history index 0 = most recent), so T4-third-marker must be
# last. The runner exits as soon as script-expect matches, so the expect is
# the LAST line's own marker (its echo) — the whole burst (including the
# HISTORY.TXT save) completes within the runner's next poll.
SCRIPT1="$RUN_DIR/script1.txt"
cat > "$SCRIPT1" <<'EOF'
echo T4-first-command
echo T4-second-unique
echo history-live-ready
echo T4-third-marker
EOF

# boot 2 needs --script to enter the runner's script mode (script2 and
# script-expect only take effect there), but must not type anything that
# pollutes the top of the recalled history — an empty script file.
: > "$RUN_DIR/empty.txt"

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
printf '\rinput\recho history-live-ok\r' > "$RUN_DIR/keys.txt"
CHORDS="up"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag-boot1.log" "$RUN_DIR/vm-serial-$tag-boot2.log"

    # Boot 1: build history
    set +e
    gate_shared_disk_lock
    host/vm-runner/.build/release/VMRunner artifacts/disk.img \
        --serial "$RUN_DIR/vm-serial-$tag-boot1.log" \
        --script "$SCRIPT1" --script-expect "T4-third-marker" --timeout 30 \
        > "$(art live-history-run-$tag-boot1.txt)" 2>&1
    local RC1=$?
    gate_shared_disk_unlock
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag-boot1.log" ] && cp "$RUN_DIR/vm-serial-$tag-boot1.log" "$(art live-history-serial-$tag-boot1.log)" || true

    if [ "$RC1" != 0 ]; then
        echo "$tag: boot1 failed rc=$RC1" | tee -a "$REPORT"
        return 1
    fi

    # Boot 2: verify history survived, recall via Up arrow (KEYBOARD)
    rm -f "$RUN_DIR/efi-vars.bin"
    set +e
    gate_shared_disk_lock
    host/vm-runner/.build/release/VMRunner artifacts/disk.img \
        --serial "$RUN_DIR/vm-serial-$tag-boot2.log" \
        --input --display \
        --script "$RUN_DIR/empty.txt" \
        --input-chords "$CHORDS" --input-chords-after "dipshit> " \
        --input-chords-delay 2.0 \
        --script2 "$RUN_DIR/keys.txt" --script2-after "dipshit> " --script2-delay 15 \
        --script-expect "history-live-ok" \
        --timeout 60 \
        > "$(art live-history-run-$tag-boot2.txt)" 2>&1
    local RC2=$?
    gate_shared_disk_unlock
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag-boot2.log" ] && cp "$RUN_DIR/vm-serial-$tag-boot2.log" "$(art live-history-serial-$tag-boot2.log)" || true
    SER="$RUN_DIR/vm-serial-$tag-boot2.log"
    RUN2="$(art live-history-run-$tag-boot2.txt)"

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 MARKER=0 INREPORT=0 OK=0 RUNNERFLAG=0
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        # Only present if the keyboard Up chord recalled the persisted line
        # (history is not printed at load in boot 2).
        grep -qF -- "T4-third-marker" "$SER" && MARKER=1
        # The shell's input report proves the Up chord decoded exactly once
        # (a lost chord would show events=0 and fail honestly).
        grep -qF -- "input: armed=1 fifo=0/64 dropped=0 events=1" "$SER" && INREPORT=1
        grep -qF -- "history-live-ok" "$SER" && OK=1
    fi
    grep -a -qF -- "input-chords: ENABLED" "$RUN2" && RUNNERFLAG=1
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
    echo "boot 1: build history with distinctive commands (canonical artifacts/disk.img under gate_shared_disk_lock)"
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
