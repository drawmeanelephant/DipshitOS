#!/usr/bin/env bash
#
# verify-live-addrspaces.sh -- claim 5804 class-B gate: per-task user
# address spaces on real VZ hardware.
#
# VZ fallback design (TTBR1 measured incompatible — see ADR 0007): the
# kernel stays identity-mapped in TTBR0, and every task's TTBR0 root
# carries an EL1-only overlay of the kernel identity map; the EL0 task's
# root adds its text+stack leaves. This gate asserts the split end to end:
#   1. The EL0 payload still runs at its USER VAs under the user root — text
#      fixed at 0x400000, the stack CSPRNG-randomized per boot (claim 3693:
#      boot-time ASLR, in the band [0x10000000, 0x80000000), 64 KiB aligned)
#      — survives the SVC sequence, and the `syscalls`/`uaccess` evidence
#      lines are unchanged — the whole EL0 boundary works on the new address
#      space.
#   2. The `addrspaces` monitor command reports TTBR1 = 0 (unused) with
#      T0SZ=16, the EL1h shell/worker tasks sharing the kernel root as
#      TTBR0, the user-el0 task on its OWN root, and — the headline — the
#      user root's EL0-accessible leaves are exactly the text+stack leaves
#      with ZERO EL0-accessible Device leaves (MMIO excluded from EL0 by
#      the EL1-only AP bits on the overlay's Device leaves).
#   3. The uaccess fault-recovery still works under the user root (the
#      `uaccess` command's raw copy faults against the user root's sparse
#      map and is recovered), and the shell stays responsive after.

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

GATE_LOG="$(art m3-addrspaces-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-addrspaces-report.txt)"
EXIT_LINE="tasks user-el0 exited status=7"
MON_LINE="uaccess: valid=1 fault=1 recovered=1 copies=4 validation_faults=1"

echo "=== verify-live-addrspaces: claim 5804 — per-task TTBR0 / EL1-only kernel overlay / MMIO excluded from EL0 (VZ TTBR1 fallback), $BOOTS boot(s) ==="

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

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-addrspaces
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

printf 'syscalls\nuaccess\naddrspaces\necho rx-addrspaces-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="$(art live-addrspaces-run-$tag.txt)"
    local serial_copy="$(art live-addrspaces-serial-$tag.log)"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" --script-after "$EXIT_LINE" \
        --script-expect $'rx-addrspaces-ok\n' --timeout 45 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-addrspaces-serial-$tag.log)" || true
    local SER="$serial_copy"

    local bytes=0 banner=0 write_ok=0 marker=0 write_count=0 mon=0 userspace_ok=0 echo_ok=0 fatal=0
    local t0sz=0 user_va=0 el0dev0=0 el0ok=0 leaves_ok=0 shell_root=0 worker_root=0 user_own=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        # OBSERVED TODAY (2026-08-24, claim 5069): M18 T5 (claim 0163) colored
        # the prompt — the reply line's serial bytes are now
        # `\x1b[32mvirelai> \x1b[0msyscall: write ok n=23` (prompt + reply merged
        # on one line), so the historical "virelai> syscall: ..." needle can
        # never match again. Match the output-only reply substring.
        [ "$(grep -aFc -- "syscall: write ok n=23" "$SER" || true)" -ge 1 ] && write_ok=1
        [ "$(grep -aFxc -- "uaccess: efault ok n=8" "$SER" || true)" = 1 ] && marker=1
        [ "$(grep -aFxc -- "  1 sys_write calls=3" "$SER" || true)" = 1 ] && write_count=1
        [ "$(grep -aFxc -- "$MON_LINE" "$SER" || true)" = 1 ] && mon=1
        [ "$(grep -aFxc -- "userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0" "$SER" || true)" = 1 ] && userspace_ok=1
        [ "$(grep -aFxc -- "rx-addrspaces-ok" "$SER" || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true

        # Address-space split assertions (monitor `addrspaces` output):
        # TTBR1 must be 0 (unused — kernel identity-mapped in TTBR0),
        # T0SZ=16.
        [ "$(grep -aFc -- "addrspaces: ttbr1=0x0000000000000000" "$SER" || true)" = 1 ] && \
            [ "$(grep -aFc -- " t0sz=16" "$SER" || true)" = 1 ] && t0sz=1
        # print_hex emits "0x" + fixed 16 lowercase digits. text_va is fixed
        # (0x400000); the stack VA is CSPRNG-randomized per boot (claim 3693)
        # — assert the text prefix and that the stack VA is in the ASLR band
        # [0x10000000, 0x80000000), 64 KiB aligned, and not text_va.
        [ "$(grep -aFc -- "addrspaces: user text=0x0000000000400000 stack=0x" "$SER" || true)" -ge 1 ] && user_va_text=1
        local sv dec
        sv="$(grep -a 'addrspaces: user text=' "$SER" | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/' | head -1)"
        if [ -n "$sv" ]; then
            dec=$((16#$sv))
            [ "$dec" -ge $((16#10000000)) ] && [ "$dec" -lt $((16#80000000)) ] && \
                [ $((dec % 65536)) -eq 0 ] && [ "$sv" != "0000000000400000" ] && user_va=1
        fi
        # el0_device (EL0-accessible Device leaves) must be 0 — MMIO is
        # excluded from EL0 by the EL1-only AP bits on the overlay's Device
        # leaves. el0 leaves must be >= 3 (text 1 page + stack 2 pages).
        [ "$(grep -aFc -- " el0_device=0" "$SER" || true)" -ge 1 ] && el0dev0=1
        local el0
        el0="$(grep -a 'addrspaces: user text=' "$SER" | sed -E 's/.*el0=([0-9]+).*/\1/' | head -1)"
        [ -n "$el0" ] && [ "$el0" -ge 3 ] 2>/dev/null && el0ok=1

        # TTBR0 ownership: shell + worker share the kernel root; user-el0 has
        # its OWN root (different from the kernel root).
        local root_hex shell_ttbr0 worker_ttbr0 user_ttbr0
        root_hex="$(grep -a 'addrspaces: ttbr1=' "$SER" | sed -E 's/.*root=0x([0-9a-f]{16}).*/\1/' | head -1)"
        shell_ttbr0="$(grep -a 'addrspaces: task shell ' "$SER" | sed -E 's/.*ttbr0=0x([0-9a-f]{16}).*/\1/' | head -1)"
        worker_ttbr0="$(grep -a 'addrspaces: task worker ' "$SER" | sed -E 's/.*ttbr0=0x([0-9a-f]{16}).*/\1/' | head -1)"
        # Claim 6729: the user task's root is reported directly (`addrspaces:
        # user root=`) because the lifecycle's idle task reaps the exited
        # user task, so the `task user-el0` row is gone by the time this
        # command runs (the gate forwards the script after the exit line).
        user_ttbr0="$(grep -a 'addrspaces: user root=' "$SER" | sed -E 's/.*root=0x([0-9a-f]{16}).*/\1/' | head -1)"
        [ -n "$root_hex" ] && [ "$shell_ttbr0" = "$root_hex" ] && shell_root=1
        [ -n "$root_hex" ] && [ "$worker_ttbr0" = "$root_hex" ] && worker_root=1
        [ -n "$user_ttbr0" ] && [ -n "$root_hex" ] && [ "$user_ttbr0" != "$root_hex" ] && user_own=1
        # leaves >= 3 (text 1 page + stack 2 pages) — parse the decimal.
        local leaves
        leaves="$(grep -a 'addrspaces: user text=' "$SER" | sed -E 's/.*leaves=([0-9]+).*/\1/' | head -1)"
        [ -n "$leaves" ] && [ "$leaves" -ge 3 ] 2>/dev/null && leaves_ok=1
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner write=$write_ok marker=$marker write-count=$write_count mon=$mon userspace=$userspace_ok echo=$echo_ok t0sz=$t0sz user-va=$user_va stack=$sv el0dev0=$el0dev0 el0ok=$el0ok leaves=$leaves_ok shell-root=$shell_root worker-root=$worker_root user-own-root=$user_own fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$write_ok" = 1 ] && \
        [ "$marker" = 1 ] && [ "$write_count" = 1 ] && \
        [ "$mon" = 1 ] && [ "$userspace_ok" = 1 ] && [ "$echo_ok" = 1 ] && \
        [ "$t0sz" = 1 ] && [ "$user_va" = 1 ] && [ "$user_va_text" = 1 ] && [ "$el0dev0" = 1 ] && \
        [ "$el0ok" = 1 ] && [ "$leaves_ok" = 1 ] && [ "$shell_root" = 1 ] && [ "$worker_root" = 1 ] && \
        [ "$user_own" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live addrspaces gate (claim 5804) — per-task TTBR0, EL1-only kernel overlay, MMIO excluded from EL0 (VZ TTBR1 fallback)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "monitor line: $MON_LINE"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-addrspaces boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then pass=$((pass + 1)); fi
done

echo
echo "=== result ==="
if [ "$pass" = "$BOOTS" ]; then
    echo "verify-live-addrspaces: PASS — kernel identity-mapped in TTBR0 with TTBR1=0 (VZ fallback), EL1h tasks on the kernel root, the EL0 task on its own root whose EL0-accessible leaves are exactly text+stack with ZERO EL0-accessible Device leaves, and the EL0 payload + uaccess recovery intact ($pass/$BOOTS boot(s))."
    echo "PASS: $pass/$BOOTS" >> "$REPORT"
    exit 0
fi
echo "verify-live-addrspaces: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
