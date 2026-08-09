#!/usr/bin/env bash
#
# verify-live-fs.sh -- claim 3475 class-B gate: the ESP file window. M1.5
# hard gate 5 ("ls, cat, and write persist through reboot") observed end to
# end on real VZ hardware.
#
# Mechanism: kernel/src/esp.zig snapshots the ESP root PRE-exit via the
# EFI Simple File System protocol (the loader's proven pattern) into a
# bounded BSS window; `ls` lists it, `cat` prints snapshotted content, and
# `write` persists content as the non-volatile EFI runtime variable
# `DipshitF:<name>` (SetVariable is proven alive post-exit on VZ, claims
# 0009/0015). The runner's VZEFIVariableStore file (artifacts/efi-vars.bin)
# survives across boots, so a file written in one boot is scanned back in
# (`GetNextVariableName`/`GetVariable`) at the next boot and visible to
# `ls`/`cat` — persistence through reboot.
#
# The gate is TWO boots against the SAME variable store:
#   run A (fresh store):  script `write hello.txt hello world` + `ls` +
#                         `cat hello.txt`; asserts the write-ok reply, the
#                         ESP snapshot listing (KERNEL.BIN / BOOTED.TXT),
#                         hello.txt listed as [nvram], and the cat reply.
#   run B (same store):   script `ls` + `cat hello.txt`; asserts hello.txt
#                         still listed as [nvram] and cat still prints the
#                         content — the file persisted across the reboot.
# The boot-time `esp window: esp=.. nvram=..` line is asserted in both runs
# (the snapshot ran; run B's listing of hello.txt is the persistence proof).
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts the full transcript (write reply, ls listing
# lines, cat reply), so an early exit on the echoed input line cannot pass.
# The [nvram] listing marker — not the echoed filename — is the proof the
# entry is in the window. The ESP itself is READ-ONLY this milestone:
# NVRAM variables are the persistence medium (a full FAT storage driver
# remains deferred at march step 15).
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-fs.sh            # one A/B pair (2 boots)
#   BOOTS=2 bash tools/verify-live-fs.sh    # two A/B pairs
#
# Evidence saved under artifacts/: live-fs-gate.txt (full output),
# live-fs-report.txt (per-run detail), live-fs-run-<A|B>-<NN>.txt (runner
# output), live-fs-serial-<A|B>-<NN>.log (vm-serial.log copies),
# live-fs-script-<A|B>.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-fs-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="artifacts/live-fs-report.txt"

echo "=== verify-live-fs: claim 3475 — ESP file window (ls/cat/write persist through reboot), $PAIRS pair(s) of boots ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-fs-script-A.txt <<'EOF'
write hello.txt hello world
ls
cat hello.txt
EOF
cat > artifacts/live-fs-script-B.txt <<'EOF'
ls
cat hello.txt
EOF

# --- per-run gate ------------------------------------------------------------
# $1 = tag, $2 = script file, $3 = expect substring, $4 = fresh store (1|0).
# Returns 0 iff the runner saw the expected reply AND every transcript
# assertion held. For run A the write-ok reply is additionally required.
run_one() {
    local tag="$1" script="$2" expect="$3" fresh="$4"
    if [ "$fresh" = 1 ]; then
        rm -f artifacts/efi-vars.bin
    fi
    rm -f artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "artifacts/live-fs-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-fs-serial-$tag.log" || true

    local SERIAL_BYTES=0
    local WRITEOK=0 NVRAM=0 ESPFILES=0 CATREPLY=0 WINDOW=0 LSHEAD=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # The write-ok reply: "write: ok (persisted 11 bytes to EFI variable DipshitF:hello.txt)"
        grep -a -qF -- "write: ok (persisted" artifacts/vm-serial.log && WRITEOK=1
        # The persistence proof: hello.txt LISTED in the ls output as [nvram].
        grep -a -qF -- "  hello.txt" artifacts/vm-serial.log && NVRAM=1
        grep -a -qF -- "[nvram]" artifacts/vm-serial.log && NVRAM=1
        # The ESP snapshot itself is listed (real files from the disk).
        grep -a -qF -- "KERNEL.BIN" artifacts/vm-serial.log && ESPFILES=1
        grep -a -qF -- "BOOTED.TXT" artifacts/vm-serial.log && ESPFILES=1
        # The cat reply (run A: also echoed in the write line; run B: only
        # the reply can produce it).
        grep -a -qF -- "hello world" artifacts/vm-serial.log && CATREPLY=1
        # The boot-time window line proves the snapshot+scan ran at boot.
        grep -a -qF -- "esp window: esp=" artifacts/vm-serial.log && WINDOW=1
        grep -a -qF -- "ls: esp=" artifacts/vm-serial.log && LSHEAD=1
    fi
    local PASS=0
    if [ "$RC" = 0 ] && [ "$WINDOW" = 1 ] && [ "$LSHEAD" = 1 ] && [ "$ESPFILES" = 1 ] && [ "$NVRAM" = 1 ] && [ "$CATREPLY" = 1 ]; then
        PASS=1
    fi
    if [ "$tag" = "A" ] && [ "$WRITEOK" != 1 ]; then
        PASS=0
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK nvram-listed=$NVRAM esp-files=$ESPFILES cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK nvram-listed=$NVRAM esp-files=$ESPFILES cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live ESP file-window gate (claim 3475) — ls/cat/write on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: write hello.txt 'hello world' + ls + cat (fresh variable store)"
    echo "run B: ls + cat hello.txt (SAME store — persistence through reboot)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-fs pair $n, run A (write/ls/cat, fresh store) ==="
    AOK=0
    run_one "A-$n" "artifacts/live-fs-script-A.txt" "hello world" 1 && AOK=1 || true
    echo "=== live-fs pair $n, run B (persistence through reboot, same store) ==="
    BOK=0
    run_one "B-$n" "artifacts/live-fs-script-B.txt" "hello world" 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-fs: PASS — ls/cat/write persist through reboot on real VZ hardware: run A persisted 'hello world' to NVRAM (write-ok, hello.txt [nvram] in ls, cat reply) and run B — a fresh boot against the same variable store — still lists and prints the file ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-fs: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-fs-report.txt and the per-run runner output/serial logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
