#!/usr/bin/env bash
#
# verify-live-reboot.sh -- claim 0527 class-B gate: live reboot/shutdown.
# M1.5 hard gate 6 ("The VM can reboot or shut down from the shell")
# observed end to end on real VZ hardware.
#
# Mechanism: the kernel's real EFI Runtime Services ResetSystem calls
# (claim 0011, kernel/src/machine.zig: cold for `reboot`, shutdown for
# `shutdown`) are driven from a LIVE virelai> shell using the runner's
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
#              boot) after the echoed `virelai> reboot`, and the VM keeps
#              running (the runner times out with the VM in boot 2, it does
#              NOT report a stop).
#   shutdown -- the machine powers off: the runner reports the VM left the
#              running state (`VM ended before the expected transcript
#              appeared (state=0)` -- VZVirtualMachine.State.stopped = 0),
#              and the serial log ends at the echoed `virelai> shutdown`
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
#   echoed          whether the echoed `virelai> <cmd>` is in the log
#   rst-marker      whether M2_RST! is in the EFI variable store (reported)
#
# Class B -- Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-reboot-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-reboot-report.txt)"
TIMEOUT="${LIVE_REBOOT_TIMEOUT:-50}"

echo "=== verify-live-reboot: claim 0527 — live reboot/shutdown (real EFI ResetSystem from a live virelai> shell), $BOOTS boot(s) per command ==="


# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
gate_fmt_check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
gate_build_runner

# --- per-run isolation -------------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
# See tools/lib/gate-run.sh.
gate_begin live-reboot
echo "run dir: $RUN_DIR"

# --- scripted keystrokes -----------------------------------------------------
cat > "$RUN_DIR/script-reboot.txt" <<'EOF'
reboot
EOF
cat > "$RUN_DIR/script-shutdown.txt" <<'EOF'
shutdown
EOF

# --- per-boot gate: one command, asserted on observed effects ----------------
# $1 = tag, $2 = command, $3 = script file. Returns 0 iff the machine-level
# effect of that command was observed.
run_one() {
    local tag="$1" cmd="$2" script="$3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-expect "__NEVER_EXPECTED__" --timeout "$TIMEOUT" \
        > "$(art live-reboot-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-reboot-serial-$tag.log)" || true
    local SER="$(art live-reboot-serial-$tag.log)"

    local SERIAL_BYTES BANNERS KEYS ECHOED STOPPED RST=0
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ' || echo 0)
    BANNERS=$(grep -a -c -- "kernel has seized control" "$SER" 2>/dev/null || echo 0)
    KEYS=$(grep -a -o -- "key=0x[0-9a-f]*" "$SER" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    # Echo form (see gate_serial_has_echo in tools/lib/gate-run.sh): the
    # interactive shell colors the prompt — `\x1b[32mvirelai> \x1b[0m<cmd>\r`
    # — but when the scripted keystroke lands while the boot-log tail is
    # still colliding with the first prompt render (first CI census, issue
    # #895), the guest echoes it PLAIN (`<cmd>\r`). Both prove the keystrokes
    # reached the console; the machine-level effect (banners/keys/stopped
    # below) is the gate's real evidence.
    if gate_serial_has_echo "$SER" "$cmd"; then ECHOED=1; else ECHOED=0; fi
    if grep -a -qF -- "VM ended before the expected transcript appeared" "$(art live-reboot-run-$tag.txt)"; then STOPPED=1; else STOPPED=0; fi
    # Claim-0011 M2_RST! marker in the EFI variable store (REPORTED, not a
    # pass criterion -- best-effort channel; see header). The store is the
    # per-run one under $RUN_DIR (claim 5069 isolation).
    if [ -f "$RUN_DIR/efi-vars.bin" ]; then
        RST=$(python3 -c "
data = open('$RUN_DIR/efi-vars.bin','rb').read()
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
    echo "VIRELAIOS live reboot/shutdown gate (claim 0527) — real EFI ResetSystem from a live virelai> shell"
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
        if run_one "$(printf '%s-%02d' "$cmd" "$n")" "$cmd" "$RUN_DIR/script-$cmd.txt"; then
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
