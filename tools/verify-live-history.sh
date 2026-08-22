#!/usr/bin/env bash
#
# verify-live-history.sh -- milestone-eighteen card T4 class-B gate (issue #407):
# persistent command history saved to HISTORY.TXT on FAT, loaded on boot.
#
# Mechanism: boots the production image, types distinctive commands to
# build history, reboots (new VM session), and verifies Up arrow recalls
# the most recent command from the persisted file.
#
# The walk:
#   Boot 1: type commands, then shutdown signal
#     echo T4-first-command
#     echo T4-second-unique
#     echo T4-third-marker
#     echo history-live-ready   -> marker for phase completion
#   Boot 2: verify history survived reboot
#     Up arrow                  -> should recall "echo T4-third-marker"
#     Enter                     -> re-executes, output proves recall
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
SCRIPT1="artifacts/live-history-script1.txt"
cat > "$SCRIPT1" <<'EOF'
echo T4-first-command
echo T4-second-unique
echo T4-third-marker
echo history-live-ready
EOF

# --- boot 2: verify recall ---------------------------------------------------
SCRIPT2="artifacts/live-history-script2.txt"
INPUT2=$'\x1b[A\x0d'
cat > "$SCRIPT2" <<'EOF'
echo history-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    # Boot 1: build history
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT1" --script-expect "history-live-ready" --timeout 30 \
        > "artifacts/live-history-run-$tag-boot1.txt" 2>&1
    local RC1=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-history-serial-$tag-boot1.log" || true

    if [ "$RC1" != 0 ]; then
        echo "$tag: boot1 failed rc=$RC1" | tee -a "$REPORT"
        return 1
    fi

    # Boot 2: verify history survived, recall via Up arrow
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT2" \
        --input-string "$INPUT2" \
        --input-string-after "dipshit> " \
        --script-expect "history-live-ok" \
        --timeout 30 \
        > "artifacts/live-history-run-$tag-boot2.txt" 2>&1
    local RC2=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-history-serial-$tag-boot2.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 MARKER=0 OK=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "T4-third-marker" artifacts/vm-serial.log && MARKER=1
        grep -qF -- "history-live-ok" artifacts/vm-serial.log && OK=1
    fi
    {
        echo "$tag: rc1=$RC1 rc2=$RC2 serial-bytes=$SERIAL_BYTES banner=$BANNER marker=$MARKER ok=$OK"
    } >> "$REPORT"
    echo "$tag rc1=$RC1 rc2=$RC2 serial-bytes=$SERIAL_BYTES banner=$BANNER marker=$MARKER ok=$OK"
    [ "$RC1" = 0 ] && [ "$RC2" = 0 ] && [ "$BANNER" = 1 ] && [ "$MARKER" = 1 ] && [ "$OK" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-history gate (M18 T4, issue #407) — persistent history on VZ"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "boot 1: build history with distinctive commands"
    echo "boot 2: recall via Up arrow, verify T4-third-marker survives reboot"
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