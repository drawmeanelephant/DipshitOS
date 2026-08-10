#!/usr/bin/env bash
#
# verify-live-entropy.sh -- claim 2665 class-B gate: the kernel's `random`
# is served by a REAL virtio entropy device on real VZ hardware.
#
# The chain, asserted in vm-serial.log across TWO boots (the
# non-determinism proof):
#   1. `entropy: seeded n=64` — the boot-time seed read 64 bytes from the
#      virtio entropy device (DID 0x1044) after the post-MMU re-arm (the
#      claim-6420 lesson applied to the entropy device) and keyed the
#      ChaCha20 CSPRNG.
#   2. `pci` lists the entropy device (`DID=0x0000000000001044`).
#   3. `random 32` emits exactly 64 lowercase hex chars on one grep-able
#      line (`random: n=32 hex=…`).
#   4. `exec USER.BIN` still loads and runs (regression) — and its reply
#      prints the CSPRNG-randomized EL0 stack VA (`stack=0x…`, the seed's
#      real ASLR consumer).
#   5. The shell stays responsive (`rx-entropy-ok`), no `[EXC] parking:`.
#   6. TWO boots produce DIFFERENT `random 32` hex AND different exec
#      stack VAs — the non-determinism proof for the CSPRNG and its
#      consumer.
#
# The script is forwarded only AFTER the static claim-8215 payload has
# exited ("tasks user-el0 exited status=7") so the user root is free when
# `exec` runs (one user program at a time); the script-expect is the exec
# reap line. Evidence saved under artifacts/live-entropy-* +
# artifacts/m4-entropy-live.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m4-entropy-live.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-2}"
REPORT="artifacts/live-entropy-report.txt"
SCRIPT="artifacts/live-entropy-script.txt"
# The static claim-8215 payload's exit line: the runner forwards the script
# only after it appears, so the user root is free when `exec` runs.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
# The exec'd program's reap line (asserted AND the script-expect — it is
# the last line in the log).
EXEC_REAP_LINE="tasks user-exec reaped"

echo "=== verify-live-entropy: claim 2665 — REAL virtio entropy -> CSPRNG seed -> random command, $BOOTS boot(s) ==="
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

printf 'pci\nrandom 32\nexec USER.BIN\necho rx-entropy-ok\n' > "$SCRIPT"

run_one() {
    local tag="$1"
    local run_log="artifacts/live-entropy-run-$tag.txt"
    local serial_copy="artifacts/live-entropy-serial-$tag.log"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log

    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$SCRIPT" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$EXEC_REAP_LINE" --timeout 60 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial_copy" || true

    local bytes=0 banner=0 seed=0 did1044=0 random_ok=0 hex_len=0 exec_ok=0 stack=0 aslr_ok=0 echo_ok=0 fatal=0
    local hex="" stack_hex="" boot_stack=""
    if [ -f artifacts/vm-serial.log ]; then
        bytes="$(wc -c < artifacts/vm-serial.log | tr -d ' ')"
        [ "$(grep -aFxc -- "DipshitOS kernel has seized control." artifacts/vm-serial.log || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "entropy: seeded n=64" artifacts/vm-serial.log || true)" = 1 ] && seed=1
        [ "$(grep -aFc -- "DID=0x0000000000001044" artifacts/vm-serial.log || true)" -ge 1 ] && did1044=1
        # Boot-time ASLR (claim 3693): the static EL0 payload's stack is
        # rebuilt at a CSPRNG-randomized VA — `aslr: boot user stack=0x…`
        # must be present and in the ASLR band.
        boot_stack="$(grep -a 'aslr: boot user stack=' artifacts/vm-serial.log | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/' | head -1 || true)"
        if [ -n "$boot_stack" ]; then
            bdec=$((16#$boot_stack))
            [ "$bdec" -ge $((16#10000000)) ] && [ "$bdec" -lt $((16#80000000)) ] && aslr_ok=1
        fi
        # `random 32` line: exactly 64 lowercase hex chars after "hex=".
        local rline
        rline="$(grep -a 'random: n=32 hex=' artifacts/vm-serial.log | head -1 || true)"
        if [ -n "$rline" ]; then
            hex="$(printf '%s' "$rline" | sed -E 's/.*hex=([0-9a-f]+)$/\1/')"
            hex_len="${#hex}"
            [ "$hex_len" = 64 ] && random_ok=1
        fi
        [ "$(grep -aFc -- "exec: loaded USER.BIN size=" artifacts/vm-serial.log || true)" = 1 ] && exec_ok=1
        local eline
        eline="$(grep -a 'exec: loaded USER.BIN' artifacts/vm-serial.log | head -1 || true)"
        if [ -n "$eline" ]; then
            stack_hex="$(printf '%s' "$eline" | sed -E 's/.*stack=0x([0-9a-f]{16}).*/\1/')"
            [ -n "$stack_hex" ] && [ "$stack_hex" != "0000000000000000" ] && stack=1
        fi
        [ "$(grep -aFxc -- "rx-entropy-ok" artifacts/vm-serial.log || true)" = 1 ] && echo_ok=1
        grep -qF -- "[EXC] parking:" artifacts/vm-serial.log && fatal=1 || true
    fi
    echo "$tag: runner-rc=$rc serial-bytes=$bytes banner=$banner seed=$seed did1044=$did1044 random=$random_ok hex-len=$hex_len exec=$exec_ok stack=$stack aslr=$aslr_ok echo=$echo_ok fatal=$fatal" | tee -a "$REPORT"
    echo "$tag: random-hex=$hex" | tee -a "$REPORT"
    echo "$tag: exec-stack-va=0x$stack_hex" | tee -a "$REPORT"
    echo "$tag: boot-stack-va=0x$boot_stack" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$seed" = 1 ] && [ "$did1044" = 1 ] && \
        [ "$random_ok" = 1 ] && [ "$exec_ok" = 1 ] && [ "$stack" = 1 ] && [ "$aslr_ok" = 1 ] && \
        [ "$echo_ok" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live entropy gate (claim 2665) — REAL virtio entropy -> CSPRNG seed -> random command"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "script: $(cat "$SCRIPT" | tr '\n' '|')"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
random_hexes=""
stack_vas=""
boot_stacks=""
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-entropy boot $n ==="
    if run_one "$(printf '%02d' "$n")"; then
        pass=$((pass + 1))
        # run_one wrote the detail lines; re-derive them for the
        # cross-boot non-determinism proof.
        tag2="$(printf '%02d' "$n")"
        h="$(sed -n "s/^$tag2: random-hex=\([0-9a-f]*\)$/\1/p" "$REPORT" | head -1)"
        s="$(sed -n "s/^$tag2: exec-stack-va=0x\([0-9a-f]*\)$/\1/p" "$REPORT" | head -1)"
        b="$(sed -n "s/^$tag2: boot-stack-va=0x\([0-9a-f]*\)$/\1/p" "$REPORT" | head -1)"
        [ -n "$h" ] && random_hexes="$random_hexes $h"
        [ -n "$s" ] && stack_vas="$stack_vas $s"
        [ -n "$b" ] && boot_stacks="$boot_stacks $b"
    fi
done

echo
echo "=== result ==="
nondet_random=0
nondet_stack=0
nondet_boot=0
if [ "$pass" = "$BOOTS" ]; then
    # The non-determinism proof: every boot's random hex must differ from
    # every other's, and every exec + boot stack VA must differ (two
    # distinct values with 2 boots).
    first_hex="$(echo "$random_hexes" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    first_stack="$(echo "$stack_vas" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    first_boot="$(echo "$boot_stacks" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
    [ "$first_hex" = "$BOOTS" ] && nondet_random=1
    [ "$first_stack" = "$BOOTS" ] && nondet_stack=1
    [ "$first_boot" = "$BOOTS" ] && nondet_boot=1
    if [ "$nondet_random" = 1 ] && [ "$nondet_stack" = 1 ] && [ "$nondet_boot" = 1 ]; then
        echo "verify-live-entropy: PASS — entropy: seeded n=64 from the REAL virtio device, random 32 emits 64 hex chars, the shell stays responsive, and $BOOTS boots produced DIFFERENT random sequences, DIFFERENT exec stack placements, AND DIFFERENT boot-time user stack placements (the CSPRNG + both ASLR consumers are non-deterministic across boots)."
        echo "PASS: $pass/$BOOTS (non-deterministic random + exec ASLR + boot ASLR)" >> "$REPORT"
        exit 0
    fi
    echo "verify-live-entropy: FAILED — all $BOOTS boots passed individually but the non-determinism proof failed (random-hexes:'$random_hexes' exec-stack-vas:'$stack_vas' boot-stack-vas:'$boot_stacks')."
    echo "FAIL: non-determinism ($pass/$BOOTS boots passed)" >> "$REPORT"
    exit 1
fi
echo "verify-live-entropy: FAILED — $pass/$BOOTS boot(s) passed; see $REPORT and per-boot logs."
echo "FAIL: $pass/$BOOTS" >> "$REPORT"
exit 1
