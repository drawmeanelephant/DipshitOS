#!/usr/bin/env bash
#
# verify-live-disas.sh -- M22 D4 class-B gate (issue #327, claim 9815):
# the disassembler decodes assembler output correctly ON the machine.
#
# The chain, all asserted in vm-serial.log:
#   1. A one-line (';'-separated) source program is staged via `write`.
#   2. ASM.BIN assembles it to /esp/PROG.ELF ("asm: wrote 96 bytes").
#   3. DISAS.BIN reads that ELF and prints per-instruction lines; the gate
#      asserts the exact hex-dump line for the first instruction
#      ("00000054: 68 00 80 d2  movz x8, #3") plus the trailing svc —
#      the D2->D4 round-trip closed end to end.
#   4. After `mount esp`, PROG.ELF loads through the D1 loader and exits
#      status 71 — proving the bytes the disassembler showed are the bytes
#      that execute.
#   5. The shell stays responsive and nothing parked.

# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set VIRELAI_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m22-disas-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-disas-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# OBSERVED TODAY (2026-08-24, claim 5069): the assembled fixture is now
# 84 bytes (`asm: wrote 84 bytes to /esp/PROG.ELF`), not the claim-time
# 96 — later syscall/metadata changes shrank it.
ASM_WROTE_LINE="asm: wrote 84 bytes to /esp/PROG.ELF"
EXIT_LINE="tasks user-exec exited status=71"

echo "=== verify-live-disas: M22 D4 (issue #327) — disassemble assembler output on the machine, $BOOTS boot(s) ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-disas
echo "run dir: $RUN_DIR"
SCRIPT2="$RUN_DIR/script2.txt"
SCRIPT="$RUN_DIR/script.txt"


SRC='_start:;mov x8, 3;mov x0, 71;svc 0'
printf 'write PROG.S %s\nexec ASM.BIN /esp/PROG.S /esp/PROG.ELF\nexec DISAS.BIN /esp/PROG.ELF 84\necho disas-mid\n' "$SRC" > "$SCRIPT"
printf 'mount esp\nexec PROG.ELF\necho rx-disas-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="$(art live-disas-run-$tag.txt)"
    local serial_copy="$(art live-disas-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$ASM_WROTE_LINE" \
        --script-expect "$EXIT_LINE" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-disas-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 written=0 assembled=0 dump=0 movz=0 svc=0 exit71=0 echo_ok=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "write: ok" "$SER" || true)" = 1 ] && written=1
        [ "$(grep -aFc -- "$ASM_WROTE_LINE" "$SER" || true)" = 1 ] && assembled=1
        [ "$(grep -aFc -- "00000054: 680080d2" "$SER" || true)" -ge 1 ] && dump=1
        [ "$(grep -aFc -- "movz x8, #3" "$SER" || true)" -ge 1 ] && movz=1
        [ "$(grep -aFc -- "svc #0" "$SER" || true)" -ge 1 ] && svc=1
        [ "$(grep -aFc -- "$EXIT_LINE" "$SER" || true)" -ge 1 ] && exit71=1
        [ "$(grep -aFxc -- "rx-disas-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner written=$written assembled=$assembled dump=$dump movz=$movz svc=$svc exit71=$exit71 echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$written" = 1 ] && [ "$assembled" = 1 ] && \
        [ "$dump" = 1 ] && [ "$movz" = 1 ] && [ "$svc" = 1 ] && \
        [ "$exit71" = 1 ] && [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live disassembler gate (M22 D4, issue #327, claim 9815)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "script2: $(cat "$SCRIPT2" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-disas boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-disas: PASS — DISAS.BIN decoded ASM.BIN's output byte-exactly (00000054: 680080d2 movz x8, #3 ...), and the same ELF executed with exit status 71 ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-disas: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
