#!/usr/bin/env bash
#
# verify-live-svc.sh -- claim 3594 class-B gate: the numbered syscall table
# on the real claim-8215 EL0/SVC boundary.
#
# The EL0 payload performs two pings and a bounded console write, waits for a
# real timer preemption, then yields and exits without returning. The
# runner sends one script only after the shell reports that exit, so the reply
# proves the shell remained responsive after the real SVC sequence.

# Run isolation (#523 item 2 / issue #528, claim 5069): every boot attaches
# a private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store (recreated fresh per boot, as the
# pre-isolation gate did), and a private serial log under $RUN_DIR — two
# concurrent instances cannot clobber each other's disks, NVRAM, or
# evidence. Set DIPSHIT_GATE_SUFFIX=_alt to give this instance its own
# canonical evidence names (two simultaneous instances MUST differ), and
# DIPSHIT_KEEP_RUN=1 to keep the scratch dir.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m3-syscall-abi-live-svc.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-svc-report.txt)"
EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-svc: claim 3594 — syscall table on EL0 SVC, $BOOTS boot(s) ==="

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-svc
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

printf 'syscalls\necho rx-svc-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-svc-run-$tag.txt)"
    local serial_copy="$(art live-svc-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$EXIT_LINE" \
        --script-expect $'rx-svc-ok\n' --timeout 45 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-svc-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 write_ok=0 ping=0 write_count=0 yield_ok=0 exit_count=0 table=0 echo_ok=0 userspace_ok=0 fatal=0 ordered=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        # OBSERVED TODAY (2026-08-24, claim 5069): M18 T5 (claim 0163) colored
        # the prompt — the reply line's serial bytes are now
        # `\x1b[32mdipshit> \x1b[0msyscall: write ok n=23` (prompt + reply merged
        # on one line), so the historical "dipshit> syscall: ..." needle can
        # never match again. Match the output-only reply substring.
        [ "$(grep -aFc -- "syscall: write ok n=23" "$SER" || true)" -ge 1 ] && write_ok=1
        [ "$(grep -aFxc -- "  0 sys_ping calls=2" "$SER" || true)" = 1 ] && ping=1
        # Claim 6120: the EL0 payload now performs three writes (good line,
        # bad-pointer EFAULT exercise, marker line), so the counter is 3.
        [ "$(grep -aFxc -- "  1 sys_write calls=3" "$SER" || true)" = 1 ] && write_count=1
        [ "$(grep -aFxc -- "  2 sys_yield calls=1" "$SER" || true)" = 1 ] && yield_ok=1
        [ "$(grep -aFxc -- "$EXIT_LINE" "$SER" || true)" = 1 ] && exit_count=1
        [ "$(grep -aFxc -- "  3 sys_exit calls=1" "$SER" || true)" = 1 ] && table=1
        [ "$(grep -aFxc -- "rx-svc-ok" "$SER" || true)" = 1 ] && echo_ok=1
        [ "$(grep -aFxc -- "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0" "$SER" || true)" = 1 ] && userspace_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
        local write_line timer_line exit_line
        write_line="$(grep -anF -- "syscall: write ok n=23" "$SER" | cut -d: -f1 | head -1)"
        timer_line="$(grep -anF -- "timer irq delivered ppi=0x1e irq_ticks=1" "$SER" | cut -d: -f1 | head -1)"
        exit_line="$(grep -anF -- "$EXIT_LINE" "$SER" | cut -d: -f1 | head -1)"
        if [ -n "$write_line" ] && [ -n "$timer_line" ] && [ -n "$exit_line" ] && \
            [ "$write_line" -lt "$timer_line" ] && [ "$timer_line" -lt "$exit_line" ]; then ordered=1; fi
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner write=$write_ok ping=$ping write-count=$write_count yield=$yield_ok exit=$exit_count table=$table echo=$echo_ok userspace=$userspace_ok ordered=$ordered fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$write_ok" = 1 ] && \
        [ "$ping" = 1 ] && [ "$write_count" = 1 ] && [ "$yield_ok" = 1 ] && \
        [ "$exit_count" = 1 ] && [ "$table" = 1 ] && [ "$echo_ok" = 1 ] && \
        [ "$userspace_ok" = 1 ] && [ "$ordered" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live SVC gate (claim 3594) — numbered syscall table on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-svc boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-svc: PASS — write/yield/exit dispatched through real EL0 SVC, counters reported, and the post-SVC shell replied ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-svc: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
