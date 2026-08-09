#!/usr/bin/env bash
#
# verify-live-reboot.sh -- claim 0527 class-B gate: live reboot/shutdown.
# M1.5 hard gate 6 ("The VM can reboot or shut down from the shell")
# observed end to end on real VZ hardware.
#
# Mechanism: the kernel's real EFI Runtime Services ResetSystem calls
# (claim 0011, kernel/src/machine.zig: cold for `reboot`, shutdown for
# `shutdown`) are driven from a LIVE dipshit> shell using the runner's
# scripted-input mode (claim 6684 --script / --script-expect: waits for the
# guest terminal state, forwards keystrokes into the serial attachment,
# tees guest output to vm-serial.log). The live shell itself is reachable
# because post-MMU virtio TX works (claim 1517) and live RX works (claim
# 6684), so the keystrokes actually reach the kernel (they are echoed at
# the prompt in the serial log).
#
# The gate observes the ResetSystem EFFECT, never a fake power-off:
#   reboot   -- the machine genuinely resets: the serial log contains a
#              SECOND complete takeover (fresh banner + memory-map print
#              with a NEW ExitBootServices key -- impossible within one
#              boot) after the echoed `dipshit> reboot`, and the VM keeps
#              running (the runner times out with the VM in boot 2, it does
#              NOT report a stop).
#   shutdown -- the machine powers off: the runner reports the VM left the
#              running state (`VM ended before the expected transcript
#              appeared (state=0)` -- VZVirtualMachine.State.stopped = 0),
#              and the serial log ends at the echoed `dipshit> shutdown`
#              with no second boot.
#
# The claim-0011 M2_RST! NVRAM marker (persisted immediately before the
# reset call) is scanned and REPORTED, but it is not a pass criterion: it
# is a best-effort channel by design (machine.zig: "A failed runtime call
# never changes control flow; the real evidence is the reset call itself"),
# and in every observed run the write was lost in the teardown race (the
# machine powers off/resets microseconds after the SetVariable), so the
# store snapshot never contains it. The machine-level effect above is the
# evidence.
#
# Per boot this reports:
#   rc              the runner's exit code (1 on timeout/stop -- expected here)
#   serial-bytes    vm-serial.log size
#   banners         number of "kernel has seized control" occurrences
#   keys            number of distinct memory-map key= values
#   echoed          whether the echoed `dipshit> <cmd>` is in the log
#   rst-marker      whether M2_RST! is in the EFI variable store (reported)
#
# Class B -- Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-reboot.sh          # BOOTS boot(s) of each command
#   BOOTS=2 bash tools/verify-live-reboot.sh
#
# Evidence saved under artifacts/: live-reboot-gate.txt (full output),
# live-reboot-report.txt (per-boot detail), live-reboot-run-<cmd>-<NN>.txt
# (runner output), live-reboot-serial-<cmd>-<NN>.log (vm-serial.log copy),
# live-reboot-script-<cmd>.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-reboot-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="artifacts/live-reboot-report.txt"
TIMEOUT="${LIVE_REBOOT_TIMEOUT:-50}"

echo "=== verify-live-reboot: claim 0527 — live reboot/shutdown (real EFI ResetSystem from a live dipshit> shell), $BOOTS boot(s) per command ==="

# --- tool versions + revision -----------------------------------------------
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

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-reboot-script-reboot.txt <<'EOF'
reboot
EOF
cat > artifacts/live-reboot-script-shutdown.txt <<'EOF'
shutdown
EOF

# --- per-boot gate: one command, asserted on observed effects ----------------
# $1 = tag, $2 = command, $3 = script file. Returns 0 iff the machine-level
# effect of that command was observed.
run_one() {
    local tag="$1" cmd="$2" script="$3"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$script" --script-expect "__NEVER_EXPECTED__" --timeout "$TIMEOUT" \
        > "artifacts/live-reboot-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-reboot-serial-$tag.log" || true

    local SERIAL_BYTES BANNERS KEYS ECHOED STOPPED RST=0
    SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log 2>/dev/null | tr -d ' ' || echo 0)
    BANNERS=$(grep -a -c -- "kernel has seized control" artifacts/vm-serial.log 2>/dev/null || echo 0)
    KEYS=$(grep -a -o -- "key=0x[0-9a-f]*" artifacts/vm-serial.log 2>/dev/null | sort -u | wc -l | tr -d ' ')
    if grep -a -qF -- "dipshit> $cmd" artifacts/vm-serial.log 2>/dev/null; then ECHOED=1; else ECHOED=0; fi
    if grep -a -qF -- "VM ended before the expected transcript appeared" "artifacts/live-reboot-run-$tag.txt"; then STOPPED=1; else STOPPED=0; fi
    # Claim-0011 M2_RST! marker in the EFI variable store (REPORTED, not a
    # pass criterion -- best-effort channel; see header).
    if [ -f artifacts/efi-vars.bin ]; then
        RST=$(python3 -c "
data = open('artifacts/efi-vars.bin','rb').read()
needle = bytes.fromhex('4d 32 5f 52 53 54 21 00')  # 'M2_RST!\x00' stored LE
print(1 if any(data[i:i+8] == needle for i in range(len(data))) else 0)
")
    fi

    local PASS=0
    case "$cmd" in
        reboot)
            # reboot must NOT stop the machine and MUST show a second full
            # takeover with a fresh map key, then sit at the prompt until
            # the runner's timeout ("not observed within").
            if [ "$ECHOED" = 1 ] && [ "$BANNERS" -ge 2 ] && [ "$KEYS" -ge 2 ] && [ "$STOPPED" = 0 ] \
               && grep -a -qF -- "not observed within" "artifacts/live-reboot-run-$tag.txt"; then
                PASS=1
            fi
            ;;
        shutdown)
            # shutdown MUST stop the machine (state=0 == .stopped) with the
            # echoed command as the last serial content and no second boot.
            if [ "$ECHOED" = 1 ] && [ "$BANNERS" -eq 1 ] && [ "$STOPPED" = 1 ] \
               && grep -a -qF -- "(state=0)" "artifacts/live-reboot-run-$tag.txt"; then
                PASS=1
            fi
            ;;
    esac

    {
        echo "$tag: cmd=$cmd rc=$RC serial-bytes=$SERIAL_BYTES banners=$BANNERS keys=$KEYS echoed=$ECHOED stopped=$STOPPED rst-marker=$RST pass=$PASS"
    } >> "$REPORT"
    echo "$tag cmd=$cmd rc=$RC serial-bytes=$SERIAL_BYTES banners=$BANNERS keys=$KEYS echoed=$ECHOED stopped=$STOPPED rst-marker=$RST pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live reboot/shutdown gate (claim 0527) — real EFI ResetSystem from a live dipshit> shell"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "scripts: reboot (cold reset), shutdown (power-off) — forwarded after the guest terminal state"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

TOTAL=0 PASS_TOTAL=0
for cmd in reboot shutdown; do
    n=0
    while [ "$n" -lt "$BOOTS" ]; do
        n=$((n + 1))
        TOTAL=$((TOTAL + 1))
        echo
        echo "=== live-$cmd boot $n ==="
        if run_one "$(printf '%s-%02d' "$cmd" "$n")" "$cmd" "artifacts/live-reboot-script-$cmd.txt"; then
            PASS_TOTAL=$((PASS_TOTAL + 1))
        fi
    done
done

echo
echo "=== result ==="
if [ "$PASS_TOTAL" = "$TOTAL" ]; then
    echo "verify-live-reboot: PASS — live reboot AND shutdown observed end to end on real VZ hardware: 'reboot' reset the machine (second full takeover, fresh map key in vm-serial.log) and 'shutdown' powered it off (VM state -> stopped) — $PASS_TOTAL/$TOTAL boot(s)."
    echo "PASS: $PASS_TOTAL/$TOTAL" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-reboot: FAILED — $PASS_TOTAL/$TOTAL boot(s) passed; see artifacts/live-reboot-report.txt and the per-boot runner output/serial logs."
    echo "FAIL: $PASS_TOTAL/$TOTAL" >> "$REPORT"
    sleep 0.5
    exit 1
fi
