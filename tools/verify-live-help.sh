#!/usr/bin/env bash
#
# verify-live-help.sh -- milestone-eight card U1 class-B gate (claim 3275):
# the ADR 0008 discovery surface on real VZ. Host scripted keystrokes type a
# `help` walk and the gate asserts the grouped catalog, the `help <command>`
# detail, and the `help <topic>` pages landed in vm-serial.log on a real boot.
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --script-expect, the claim-6684 seam). The scripted
# keystrokes are forwarded into the serial attachment, guest output is teed to
# vm-serial.log, and the runner exits 0 iff the expected reply appears.
#
# The walk:
#   help            -> grouped catalog (group headers + topic footer)
#   help net        -> per-command detail (name - help + usage line)
#   help networking -> topic page
#   help windows    -> topic page
#   help storage    -> topic page
#   help graphics   -> topic page
#   help syscalls   -> a command named like a topic: the command detail wins
#   echo help-live-ok -> the runner's success signal
#
# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-help.sh            # BOOTS boots (default 1)
#   BOOTS=3 bash tools/verify-live-help.sh
#
# Evidence saved under artifacts/: live-help-gate.txt, live-help-report.txt,
# live-help-run-<NN>.txt, live-help-serial-<NN>.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-help-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-help-report.txt)"

echo "=== verify-live-help: claim 3275 — ADR 0008 help walk on VZ, $BOOTS boot(s) ==="


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

# --- per-run isolation -------------------------------------------------------
gate_begin live-help
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# --- the scripted keystrokes ------------------------------------------------
cat > "$SCRIPT" <<'EOF'
help
help net
help networking
help windows
help storage
help graphics
help syscalls
echo help-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "help-live-ok" --timeout 40 \
        > "$(art live-help-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    local SER="$(art live-help-serial-$tag.log)"
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$SER" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 GROUP_ID=0 GROUP_MEM=0 GROUP_GFX=0 FOOTER=0 CMD_DETAIL=0 CMD_USAGE=0 TOPIC_NET=0 TOPIC_WIN=0 TOPIC_STORAGE=0 TOPIC_GFX=0 CMD_WINS=0 ECHO=0
    if [ -f "$SER" ]; then
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        # Grouped catalog: the ADR 0008 D1 group headers (not the flat list).
        # One grep per flag, each on its own line — bash 3.2 `set -e` misbehaves
        # on a backslash-continued `&&` chain inside a function.
        grep -qF -- "machine / identity" "$SER" && GROUP_ID=1
        grep -qF -- "memory / machine state" "$SER" && GROUP_MEM=1
        grep -qF -- "graphics / input" "$SER" && GROUP_GFX=1
        grep -qF -- "type 'help <topic>' for a topic page" "$SER" && FOOTER=1
        # `help net` — command detail (name - help, then the usage line).
        grep -qF -- "net - virtio-net transport" "$SER" && CMD_DETAIL=1
        grep -qF -- "usage: net [recv" "$SER" && CMD_USAGE=1
        # Topic pages.
        grep -qF -- "virtio-net (DID 0x1041), flag-gated" "$SER" && TOPIC_NET=1
        grep -qF -- "owns the window registry" "$SER" && TOPIC_WIN=1
        # M34 HF6 (issue #740): the storage topic describes the host share.
        grep -qF -- "The macOS host share (custom-virtio queue 5" "$SER" && TOPIC_STORAGE=1
        grep -qF -- "1280x720 B8G8R8X8, 2D blits only" "$SER" && TOPIC_GFX=1
        # `help syscalls` — a command wins over any topic interpretation.
        grep -qF -- "syscalls - numbered syscall table" "$SER" && CMD_WINS=1
        grep -qF -- "help-live-ok" "$SER" && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER group-id=$GROUP_ID group-mem=$GROUP_MEM group-gfx=$GROUP_GFX footer=$FOOTER cmd-detail=$CMD_DETAIL cmd-usage=$CMD_USAGE topic-net=$TOPIC_NET topic-win=$TOPIC_WIN topic-storage=$TOPIC_STORAGE topic-gfx=$TOPIC_GFX cmd-wins=$CMD_WINS echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER group-id=$GROUP_ID group-mem=$GROUP_MEM group-gfx=$GROUP_GFX footer=$FOOTER cmd-detail=$CMD_DETAIL cmd-usage=$CMD_USAGE topic-net=$TOPIC_NET topic-win=$TOPIC_WIN topic-storage=$TOPIC_STORAGE topic-gfx=$TOPIC_GFX cmd-wins=$CMD_WINS echo=$ECHO"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$GROUP_ID" = 1 ] && [ "$GROUP_MEM" = 1 ] && [ "$GROUP_GFX" = 1 ] && [ "$FOOTER" = 1 ] && [ "$CMD_DETAIL" = 1 ] && [ "$CMD_USAGE" = 1 ] && [ "$TOPIC_NET" = 1 ] && [ "$TOPIC_WIN" = 1 ] && [ "$TOPIC_STORAGE" = 1 ] && [ "$TOPIC_GFX" = 1 ] && [ "$CMD_WINS" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live-help gate (claim 3275) — the ADR 0008 help walk on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $SCRIPT (help / help net / help <topics> / help syscalls / echo help-live-ok)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-help boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-help: PASS — the grouped catalog, command detail, and topic pages are live on VZ ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-help: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-help-report.txt) and the per-boot serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
