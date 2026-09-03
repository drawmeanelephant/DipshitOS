#!/usr/bin/env bash
#
# verify-live-scripting.sh -- milestone-eighteen card T16 class-B gate
# (issue #419): basic scripting mode — `sh <script>` executes a file of
# shell commands line by line.
#
# Mechanism: boots the production image and drives the walk over serial:
#   write SCRIPT.TXT echo t16-first-marker   (create a one-line script)
#   sh SCRIPT.TXT                             -> outputs t16-first-marker
#   write INNER.TXT echo t16-inner-ran
#   write NESTED.TXT sh INNER.TXT             (a script that calls sh)
#   sh NESTED.TXT             -> "sh: scripts cannot call scripts", and
#                                t16-inner-ran must NOT appear (no nesting)
#   sh MISSING.TXT            -> honest not-found error
#   echo t16-scripting-ok     -> completion marker
#
# The multi-line two-echo case is proven by the class-A host test; the
# monitor `write` seam cannot produce newlines, so the in-VM script is
# single-line — this gate proves the end-to-end FAT write -> sh read ->
# execute path on real hardware, plus the nesting refusal and the
# missing-file error.
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
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-scripting-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-scripting-report.txt)"

echo "=== verify-live-scripting: M18 T16 — sh scripting mode on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# M34 HF6 (issue #740): `write`/`sh` operate on the --cvc-file host share,
# which requires the SPIKE runner build (the custom-virtio FILE channel).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-scripting
# M34 HF6 (issue #740): the scripting surface is the host share — arm it.
gate_arm_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"


cat > "$SCRIPT" <<'EOF'
write SCRIPT.TXT echo t16-first-marker
sh SCRIPT.TXT
write INNER.TXT echo t16-inner-ran
write NESTED.TXT sh INNER.TXT
sh NESTED.TXT
sh MISSING.TXT
write COMPL.TXT echo t16-compl-file-ok
echo t16-scripting-ok
EOF

# Phase 2: Tab completion (issue #783)
# 1. Command completion: "ver" + Tab completes to "version", Enter runs it
printf 'ver\t\n' >> "$SCRIPT"
# 2. Command candidate cycling: "ca" + Tab gives "calc", Tab cycles to "cat", Enter runs "cat"
printf 'ca\t\t\n' >> "$SCRIPT"
# 3. Argument/subverb completion: "color o" + Tab gives "off", Tab cycles to "on", Enter runs "color on"
printf 'color o\t\t\n' >> "$SCRIPT"
# 4. Host share file completion: "cat COMP" + Tab completes to "cat COMPL.TXT", Enter runs it
printf 'cat COMP\t\n' >> "$SCRIPT"
# Final marker
printf 'echo t16-completion-ok\n' >> "$SCRIPT"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    # M34 HF6 (issue #740): the shared read-only boot image + private
    # share — `write` and `sh` now operate on the host share (the FAT
    # volume is gone), so the gate arms the channel instead of locking a
    # writable disk.
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-expect "t16-completion-ok" --timeout 30 \
        > "$(art live-scripting-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-scripting-serial-$tag.log)" || true
    local SER="$(art live-scripting-serial-$tag.log)"

    local SERIAL_BYTES BANNER=0 RAN=0 NESTED=0 NOINNER=0 MISSING=0 DONE=0
    local COMP_CMD=0 COMP_CYCLE=0 COMP_ARG=0 COMP_FILE=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    if [ -f "$SER" ]; then
        grep -qF "VirelaiOS kernel" "$SER" && BANNER=1
        # t16-first-marker appears exactly twice: the typed `write` line's
        # echo plus the script's own output. A nested re-execution of
        # SCRIPT.TXT (or a double run) would add a third occurrence.
        [ "$(grep -oF -- 't16-first-marker' "$SER" | wc -l | tr -d ' ')" = 2 ] && RAN=1
        grep -qF "sh: scripts cannot call scripts" "$SER" && NESTED=1
        # t16-inner-ran appears exactly once (the typed `write` line's
        # echo). If INNER.TXT had run despite the refusal, its `echo`
        # output would add a second occurrence.
        [ "$(grep -oF -- 't16-inner-ran' "$SER" | wc -l | tr -d ' ')" = 1 ] && NOINNER=1
        grep -qF "sh: MISSING.TXT: not found (no such file on the host share)" "$SER" && MISSING=1
        grep -qF "virelai-kernel" "$SER" && COMP_CMD=1
        grep -qF "usage: cat <file|path>" "$SER" && COMP_CYCLE=1
        grep -qF "color: on" "$SER" && COMP_ARG=1
        grep -qF "t16-compl-file-ok" "$SER" && COMP_FILE=1
        grep -qF "t16-completion-ok" "$SER" && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER ran=$RAN nested=$NESTED noinner=$NOINNER missing=$MISSING comp_cmd=$COMP_CMD comp_cycle=$COMP_CYCLE comp_arg=$COMP_ARG comp_file=$COMP_FILE done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$RAN" = 1 ] && [ "$NESTED" = 1 ] && [ "$NOINNER" = 1 ] && [ "$MISSING" = 1 ] && [ "$COMP_CMD" = 1 ] && [ "$COMP_CYCLE" = 1 ] && [ "$COMP_ARG" = 1 ] && [ "$COMP_FILE" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-scripting boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-scripting: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-scripting: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
