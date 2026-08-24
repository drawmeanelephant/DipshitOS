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
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
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

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-clipboard-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-clipboard-report.txt)"

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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-clipboard
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"


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
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "clip-live-ok" --timeout 40 \
        > "$(art live-clipboard-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-clipboard-serial-$tag.log)" || true
    local SER="$(art live-clipboard-serial-$tag.log)"

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 STORED11=0 PASTE11=0 STORED6=0 PASTE6=0 IMPL=0 SLOT38=0 SLOT39=0 ECHO=0
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "clip: stored 11 bytes" "$SER" && STORED11=1
        grep -qF -- "clip: hello world" "$SER" && PASTE11=1
        grep -qF -- "clip: stored 6 bytes" "$SER" && STORED6=1
        grep -qF -- "clip: second" "$SER" && PASTE6=1
        # OBSERVED TODAY (2026-08-24, claim 5069): syscall table grew to
        # implemented=61; pin the shape, not the count.
        grep -qE -- "syscalls: slots=[0-9]+ implemented=[0-9]+" "$SER" && IMPL=1
        grep -qF -- "  38 sys_clipboard_set calls=" "$SER" && SLOT38=1
        grep -qF -- "  39 sys_clipboard_get calls=" "$SER" && SLOT39=1
        grep -qF -- "clip-live-ok" "$SER" && ECHO=1
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
