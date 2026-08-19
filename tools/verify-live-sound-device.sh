#!/usr/bin/env bash
#
# verify-live-sound-device.sh -- claim 6140 (Milestone 15, Card A1)
# class-B gate: the virtio-snd TRANSPORT on real Apple silicon VZ.
#
# The runner boots the production image with the flag-gated `--sound`
# mode (one VZVirtioSoundDeviceConfiguration + one output stream with a
# host audio sink). The guest discovers the device on PCI bus 0,
# negotiates features, arms the CONTROL queue (queue 0), reaches
# DRIVER_OK, and re-arms post-MMU. The `sound` monitor command then
# reports the OBSERVED hardware truth.
#
# Claim-time observations this gate asserts (2026-08-18, live on VZ):
#   - DID 0x1059  — the 0x1040 + virtio-device-type-25 prediction HELD.
#   - class 0x040100 (audio).
#   - st=0x0f pre-rearm — the sound device is NOT reset by VZ at
#     ExitBootServices (like net/gpu, unlike blk/entropy); recorded.
#   - rearm ok, DRIVER_OK st=0x0f, control queue armed (qsz=4).
#   - cfg reads 0/0/0 — VZ does not populate the le32 config counts
#     (a 32-byte raw dump was uniformly zero even with two output
#     streams attached; stream topology is enumerated in A2 via
#     CONTROL-queue JACK_INFO/PCM_INFO queries).
#
# A differing DID on a future run is a FINDING, not a pass: the gate
# fails loudly and the new DID must be recorded as the hardware truth.
#
# Class B — Apple silicon + VZ only; boots a real VM. A1 is the
# transport only — no audible output is expected (that is card A2).
#
# Usage:
#   bash tools/verify-live-sound-device.sh
#
# Evidence saved under artifacts/: live-sound-gate.txt,
# live-sound-report.txt, live-sound-run.txt, live-sound-serial.log,
# live-sound-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-sound-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-sound-report.txt"

echo "=== verify-live-sound-device: claim 6140 — M15 A1 virtio-snd transport on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# The script: at the prompt, run the `sound` transport report.
cat > artifacts/live-sound-script.txt <<'EOF'
sound
EOF

echo "--- Phase 1: Running the A1 sound transport on VZ (--sound) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --sound \
    --script artifacts/live-sound-script.txt \
    --script-expect "sound: cfg=" \
    --timeout 90 > artifacts/live-sound-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-sound-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-sound-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the transport markers ---"

# Host side: the --sound attach actually happened.
grep -q "SOUND: virtio-snd attached" artifacts/live-sound-run.txt || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# Guest side: pre-rearm + rearm evidence (the transport survives the MMU
# switch; st=0x0f pre-rearm = NOT reset by VZ, recorded).
grep -q "snd: pre-rearm st=0f" artifacts/live-sound-serial.log || {
    echo "ERROR: pre-rearm status line missing (expected st=0f — sound is not reset by VZ)"
    exit 1
}
echo "SND.PRE_REARM: OK (st=0x0f — not reset by VZ, like net/gpu)"

grep -q "snd: rearm ok st=0f" artifacts/live-sound-serial.log || {
    echo "ERROR: rearm did not reach DRIVER_OK (st=0x0f)"
    exit 1
}
echo "SND.REARM: OK"

# DID: the claim-time observation. A differing DID is a FINDING.
grep -q "did=0x0000000000001059" artifacts/live-sound-serial.log || {
    echo "ERROR: DID is not 0x1059 — a FINDING: record the observed DID as the hardware truth"
    exit 1
}
echo "SND.DID: OK (0x1059 — 0x1040+25 prediction held)"

grep -q "cls=0x0000000000040100" artifacts/live-sound-serial.log || {
    echo "ERROR: PCI class is not 0x040100 (audio)"
    exit 1
}
echo "SND.CLASS: OK (0x040100 audio)"

grep -q "st=0x000000000000000f" artifacts/live-sound-serial.log || {
    echo "ERROR: device status is not DRIVER_OK (0x0f)"
    exit 1
}
echo "SND.STATUS: OK (DRIVER_OK)"

grep -q "qsz=0x0000000000000004" artifacts/live-sound-serial.log || {
    echo "ERROR: control queue size is not 4"
    exit 1
}
echo "SND.QUEUE: OK (control queue armed, qsz=4)"

# The honest config-count record: VZ reports 0/0/0 (finding recorded).
grep -q "sound: cfg=jacks=0 streams=0 chmaps=0" artifacts/live-sound-serial.log || {
    echo "ERROR: the device-config counts line is missing"
    exit 1
}
echo "SND.CFG: OK (0/0/0 — VZ does not populate the le32 config counts; A2 enumerates via PCM_INFO)"

echo ""
echo "=== A1 sound transport gate PASSED on VZ ==="
{
    echo "verify-live-sound-device.sh — claim 6140 (M15 A1) — PASSED"
    echo "revision: $REVISION branch=$BRANCH"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^snd:|^sound:" artifacts/live-sound-serial.log
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" artifacts/live-sound-run.txt
} > "$REPORT"
cat "$REPORT"
