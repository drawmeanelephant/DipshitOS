#!/usr/bin/env bash
#
# verify-live-clipboard.sh -- milestone-fourteen card S1 class-B gate (claim
# 0169): the bounded shared kernel clipboard on real VZ. Host scripted
# keystrokes drive the terminal half (`clip <text...>` sets it, `clip` pastes
# it) and assert the same buffer round-trips across multiple sets/gets, then
# `syscalls` proves the ADR 0007 slots 38/39 are wired into the live dispatch
# table (implemented=46).
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --script-expect, the claim-6684 seam). The scripted
# keystrokes are forwarded into the serial attachment, guest output is teed to
# vm-serial.log, and the runner exits 0 iff the expected reply appears.
#
# The walk:
#   clip hello world -> "clip: stored 11 bytes"  (set, space-joined)
#   clip             -> "clip: hello world"      (get — non-destructive)
#   clip second      -> "clip: stored 6 bytes"   (overwrite)
#   clip             -> "clip: second"           (the NEW contents)
#   syscalls         -> implemented=46 + rows 38/39 present
#   echo clip-live-ok -> the runner's success signal
#
# The EL0 seam (sys_clipboard_set/get dispatch + fault safety) is proven at
# class-A in kernel/src/syscall.zig and will be composition-proven live with
# NOTEPAD copy/paste at card S3 (verify-live-m14-composition.sh).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-clipboard.sh          # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-clipboard.sh
#
# Evidence saved under artifacts/: live-clipboard-gate.txt,
# live-clipboard-report.txt, live-clipboard-run-<NN>.txt,
# live-clipboard-serial-<NN>.log, live-clipboard-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-clipboard-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-clipboard-report.txt"
SCRIPT="artifacts/live-clipboard-script.txt"

echo "=== verify-live-clipboard: claim 0169 — shared kernel clipboard on VZ, $BOOTS boot(s) ==="

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

# --- the scripted keystrokes ------------------------------------------------
cat > "$SCRIPT" <<'EOF'
clip hello world
clip
clip second
clip
syscalls
echo clip-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-expect "clip-live-ok" --timeout 40 \
        > "artifacts/live-clipboard-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-clipboard-serial-$tag.log" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ')
    local BANNER=0 STORED11=0 PASTE11=0 STORED6=0 PASTE6=0 IMPL=0 SLOT38=0 SLOT39=0 ECHO=0
    if [ -f artifacts/vm-serial.log ]; then
        grep -qF -- "DipshitOS kernel has seized control." artifacts/vm-serial.log && BANNER=1
        grep -qF -- "clip: stored 11 bytes" artifacts/vm-serial.log && STORED11=1
        grep -qF -- "clip: hello world" artifacts/vm-serial.log && PASTE11=1
        grep -qF -- "clip: stored 6 bytes" artifacts/vm-serial.log && STORED6=1
        grep -qF -- "clip: second" artifacts/vm-serial.log && PASTE6=1
        grep -qF -- "syscalls: slots=64 implemented=46" artifacts/vm-serial.log && IMPL=1
        grep -qF -- "  38 sys_clipboard_set calls=" artifacts/vm-serial.log && SLOT38=1
        grep -qF -- "  39 sys_clipboard_get calls=" artifacts/vm-serial.log && SLOT39=1
        grep -qF -- "clip-live-ok" artifacts/vm-serial.log && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER stored11=$STORED11 paste11=$PASTE11 stored6=$STORED6 paste6=$PASTE6 impl=$IMPL slot38=$SLOT38 slot39=$SLOT39 echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER stored11=$STORED11 paste11=$PASTE11 stored6=$STORED6 paste6=$PASTE6 impl=$IMPL slot38=$SLOT38 slot39=$SLOT39 echo=$ECHO"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$STORED11" = 1 ] && [ "$PASTE11" = 1 ] && [ "$STORED6" = 1 ] && [ "$PASTE6" = 1 ] && [ "$IMPL" = 1 ] && [ "$SLOT38" = 1 ] && [ "$SLOT39" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-clipboard gate (claim 0169) — the bounded shared kernel clipboard on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (clip set/get x2 + syscalls + echo clip-live-ok)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-clipboard boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-clipboard: PASS — the shared kernel clipboard round-trips live on VZ (set/overwrite/get through the terminal half) and the syscalls report shows implemented=46 with slots 38/39 present ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-clipboard: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-clipboard-report.txt and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
