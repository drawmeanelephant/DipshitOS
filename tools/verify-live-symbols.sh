#!/usr/bin/env bash
#
# verify-live-symbols.sh -- M22 D3 class-B gate (issue #326, claim 9815):
# crash reports carry function names resolved through the kernel symbol
# table.
#
# The chain, all asserted in vm-serial.log:
#   1. CRASH.ELF (tools/mkhello-elf.py --crash) is embedded on the ESP with
#      a real .symtab: one GLOBAL FUNC "crasher" covering its code block.
#   2. `exec CRASH.ELF` loads it through the D1 ELF path — exec_file copies
#      the .symtab entries into the kernel BSS symbol table (symbol.zig).
#   3. The program executes `brk #0` at crasher+4: EC 0x3c sync fault from
#      EL0 → the fault dispatcher reaps it with status 139 and records the
#      PC alongside FAR in the tombstone.
#   4. `sym` lists the loaded symbols ("crasher addr=0x400000 ...").
#   5. `crash` prints the tombstone WITH the resolved note
#      "(in crasher+0x4)" — the gate's headline assertion.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m22-symbols-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-symbols-report.txt"
SCRIPT="artifacts/live-symbols-script.txt"
SCRIPT2="artifacts/live-symbols-script2.txt"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
CRASH_EXIT_LINE="tasks user-exec exited status=139"

echo "=== verify-live-symbols: M22 D3 (issue #326) — symbolized crash reports, $BOOTS boot(s) ==="
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

printf 'exec CRASH.ELF\necho sym-mid\n' > "$SCRIPT"
printf 'sym\ncrash\necho rx-sym-ok\n' > "$SCRIPT2"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-symbols-run-$tag.txt"
    local serial_copy="artifacts/live-symbols-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" --script2-after "$CRASH_EXIT_LINE" \
        --script-expect "rx-sym-ok" --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 listed=0 loaded=0 exited139=0 symlist=0 note=0 echo_ok=0 fatal=0
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "CRASH.ELF" artifacts/vm-serial.log || true)" -ge 2 ] && listed=1
        [ "$(grep -aFc -- "exec: loaded CRASH.ELF size=" artifacts/vm-serial.log || true)" = 1 ] && loaded=1
        [ "$(grep -aFc -- "$CRASH_EXIT_LINE" artifacts/vm-serial.log || true)" -ge 1 ] && exited139=1
        [ "$(grep -aFc -- "crasher addr=0x0000000000400000" artifacts/vm-serial.log || true)" -ge 1 ] && symlist=1
        [ "$(grep -aFc -- "(in crasher+0x4)" artifacts/vm-serial.log || true)" -ge 1 ] && note=1
        [ "$(grep -aFxc -- "rx-sym-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner listed=$listed loaded=$loaded exited139=$exited139 symlist=$symlist note=$note echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$listed" = 1 ] && [ "$loaded" = 1 ] && \
        [ "$exited139" = 1 ] && [ "$symlist" = 1 ] && [ "$note" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live symbolized-crash gate (M22 D3, issue #326, claim 9815)"
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
    echo "=== live-symbols boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-symbols: PASS — CRASH.ELF's symtab populated the kernel table, its BRK produced a status-139 tombstone, and 'crash' resolved the PC to '(in crasher+0x4)' ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-symbols: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
