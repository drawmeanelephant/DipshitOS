#!/usr/bin/env bash
#
# verify-live-sb2-shared-anon.sh -- M33 SB2 (claim 8878) class-B gate: the
# shared-anonymous mmap capability end to end on real VZ hardware (ADR 0016).
#
# Two EL0 processes map ONE physical region through sys_mmap (slot 63) with
# the M33_MAP_SHARED flag (bit 16):
#   * SB2WM.BIN  — the WM (peer) half: registers as the WM server (slot 65),
#     receives the owner's {pid, handle, magic} handshake over the mailbox,
#     attaches the surface READ-ONLY by handle (EL0-RO sw_cow leaf in ITS OWN
#     root), reads the owner's byte and prints `sb2: wm-read=0xAB`.
#   * SB2OWN.BIN — the owner half: creates the shared surface (its WRITABLE
#     leaf), renders the magic byte into it, sends the handshake, waits for
#     the WM's read-ack, then sends "bye" and exits — the exit path revokes
#     the WM's RO view (ADR 0016 D2 revocation-on-teardown).
#   * The WM then RE-attaches the now-stale handle and prints
#     `sb2: wm-reattach=EFAULT` — the live proof that no peer retains access
#     past the owner (a stale WM mirror cannot re-map the region).
#
# Serial evidence (the gate's grep targets, pinned host-side in the apps):
#   sb2: wm registered   sb2: own created   sb2: wm-read=0xAB
#   sb2: own ack         sb2: owner done    sb2: wm-reattach=EFAULT
#   sb2: wm done
#
# Fully CI-runnable with NO Accessibility trust — pure serial + mailbox, no
# pointer/keyboard injection.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-sb2-shared-anon.sh
# Evidence: artifacts/live-sb2-shared-anon-{run.txt,serial.log},
#           artifacts/live-sb2-shared-anon-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/630 (seam B)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sb2-shared-anon-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sb2-shared-anon-report.txt)"

echo "=== verify-live-sb2-shared-anon: M33 SB2 — two EL0 roots map one physical region; owner writes, WM reads RO; owner exit revokes the peer (ADR 0016) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-sb2-shared-anon
echo "run dir: $RUN_DIR"

SER_LOG="$(art live-sb2-shared-anon-serial.log)"
RUN_LOG="$(art live-sb2-shared-anon-run.txt)"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

printf 'exec SB2WM.BIN\nexec SB2OWN.BIN\n' > "$RUN_DIR/script.txt"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --screen "$RUN_DIR/screen" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-expect $'sb2: wm done\n' --timeout 180 > "$RUN_LOG" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$SER_LOG" || true

echo "runner-rc=$RC serial-bytes=$( [ -f "$SER_LOG" ] && wc -c < "$SER_LOG" | tr -d ' ' || echo 0 )"

OK=0
A_WM_REG=0
A_OWN_CREATE=0
A_WM_READ=0
A_OWN_ACK=0
A_OWN_DONE=0
A_REATTACH=0
A_WM_DONE=0
A_FAULT=0
if [ "$RC" = 0 ] && [ -f "$SER_LOG" ]; then
    grep -a -qF -- "sb2: wm registered" "$SER_LOG" && A_WM_REG=1
    grep -a -qF -- "sb2: own created" "$SER_LOG" && A_OWN_CREATE=1
    grep -a -qF -- "sb2: wm-read=0xAB" "$SER_LOG" && A_WM_READ=1
    grep -a -qF -- "sb2: own ack" "$SER_LOG" && A_OWN_ACK=1
    grep -a -qF -- "sb2: owner done" "$SER_LOG" && A_OWN_DONE=1
    grep -a -qF -- "sb2: wm-reattach=EFAULT" "$SER_LOG" && A_REATTACH=1
    grep -a -qF -- "sb2: wm done" "$SER_LOG" && A_WM_DONE=1
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_LOG" && A_FAULT=1 || true
    if [ "$A_WM_REG" = 1 ] && [ "$A_OWN_CREATE" = 1 ] && [ "$A_WM_READ" = 1 ] && \
        [ "$A_OWN_ACK" = 1 ] && [ "$A_OWN_DONE" = 1 ] && [ "$A_REATTACH" = 1 ] && \
        [ "$A_WM_DONE" = 1 ] && [ "$A_FAULT" = 0 ]; then
        OK=1
    fi
fi
echo "wm-reg=$A_WM_REG own-create=$A_OWN_CREATE wm-read=$A_WM_READ own-ack=$A_OWN_ACK own-done=$A_OWN_DONE reattach=$A_REATTACH wm-done=$A_WM_DONE fatal=$A_FAULT" | tee -a "$REPORT"

{
    echo "VIRELAIOS live shared-anon gate (claim 8878) — two EL0 roots, one physical region; owner RW, WM RO; owner exit revokes the peer (ADR 0016)"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo
echo "=== result ==="
if [ "$OK" = 1 ]; then
    echo "verify-live-sb2-shared-anon: PASS — the owner created the shared surface, wrote 0xAB; the registered WM attached it READ-ONLY by handle and read 0xAB; after the owner exited the WM's stale re-attach returned EFAULT (revocation)."
    echo "PASS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sb2-shared-anon: FAILED — see $REPORT and $SER_LOG."
echo "FAIL" >> "$REPORT"
exit 1
