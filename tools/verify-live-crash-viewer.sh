#!/usr/bin/env bash
#
# verify-live-crash-viewer.sh -- M22 D11 (issue #334) class-B gate:
# the `crash <index>` tombstone report viewer on real VZ hardware.
#
# Mechanism: boots the production image and execs CRASH.ELF (its BRK faults
# at crasher+0x4 with a real symtab-loaded symbol table). exec is
# asynchronous, so the viewer commands ride the runner's second script
# phase, gated on the status-139 exit line; then `crash 0` must render the
# D11 detail-report shape: the resolved symbol note `(in crasher+0x4)` and
# the serial-snapshot section.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-crash-viewer.sh
#
# Evidence saved under artifacts/: live-crash-viewer-gate.txt,
# live-crash-viewer-report.txt, live-crash-viewer-run-*.txt,
# live-crash-viewer-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-crash-viewer-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-crash-viewer-report.txt)"
CRASH_EXIT_LINE="tasks user-exec exited status=139"
BOOT_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-crash-viewer: M22 D11 — crash report viewer on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-crash-viewer
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
SCRIPT2="$RUN_DIR/script2.txt"

printf 'exec CRASH.ELF\necho cv-mid\n' > "$SCRIPT"
printf 'crash 1\necho rx-crashview-ok\n' > "$SCRIPT2"
# NOTE: tombstone 0 is the boot payload's exit-7 record (PID 0); the
# CRASH.ELF BRK lands at index 1 deterministically after it.

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$BOOT_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$CRASH_EXIT_LINE" \
        --script-expect "rx-crashview-ok" \
        --timeout 90 \
        > "$(art live-crash-viewer-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-crash-viewer-serial-$tag.log)" || true
    local SER="$(art live-crash-viewer-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 EXITED=0 TOMBSTONE=0 SYMBOL=0 SNAPSHOT=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "exited status=139" "$SER" && EXITED=1
        grep -qF -- "VirelaiOS Crash Tombstone" "$SER" && TOMBSTONE=1
        grep -qF -- "(in crasher+0x4)" "$SER" && SYMBOL=1
        grep -qF -- "--- Last Serial Output ---" "$SER" && SNAPSHOT=1
        grep -qF -- "rx-crashview-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER exited139=$EXITED tombstone=$TOMBSTONE symbol=$SYMBOL snapshot=$SNAPSHOT reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER exited139=$EXITED tombstone=$TOMBSTONE symbol=$SYMBOL snapshot=$SNAPSHOT reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$EXITED" = 1 ] && [ "$TOMBSTONE" = 1 ] \
    && [ "$SYMBOL" = 1 ] && [ "$SNAPSHOT" = 1 ] && [ "$REPLY" = 1 ]
}

PASS=0
i=1
while [ "$i" -le "$BOOTS" ]; do
    TAG="$(printf '%02d' "$i")"
    if run_one "$TAG"; then
        PASS=$((PASS + 1))
    fi
    i=$((i + 1))
done

gate_end

[ "$PASS" -ge 1 ] || { echo "verify-live-crash-viewer: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-crash-viewer-report.txt)"; exit 1; }
echo "=== verify-live-crash-viewer: PASS — crash 0 rendered the detailed tombstone with the resolved symbol (in crasher+0x4) and the serial snapshot ($PASS/$BOOTS boot(s)). ==="
