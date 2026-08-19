#!/usr/bin/env bash
#
# verify-live-sound-playback.sh -- claim 5877 (Milestone 15, Card A2)
# class-B gate: the PCM playback path on real Apple silicon VZ.
#
# The runner boots the production image with `--sound` and runs the
# `beep 440 300` monitor command. The guest drives the full virtio-snd
# control flow and TX submission:
#
#   PCM_INFO (the A1-finding workaround — VZ does not populate the le32
#     config counts, so the stream is enumerated by asking) →
#   PCM_SET_PARAMS → PCM_PREPARE → PCM_START → TX-queue submits (4096-byte
#     periods of a synthesized FLOAT-stereo-48 kHz sine) → used-ring drain
#     per period → PCM_STOP → PCM_RELEASE.
#
# Claim-time observations this gate asserts (2026-08-18, live on VZ):
#   - VZ speaks the virtio-1.3 control renumbering: status OK = 0x8000
#     (a 1.2-style code 3 request was answered with BAD_MSG 0x8001).
#   - The control reply layout is [status hdr][info entries] — status
#     FIRST (the Linux driver reads it last; VZ writes it first).
#   - PCM_INFO(0) advertises formats bits 5/17/19 (S16|S32|FLOAT), rates
#     bits 7/10 (48000|96000), channels 1..2, direction OUTPUT.
#   - The negotiated stream: FLOAT (19), 48000 (7), stereo (2).
#   - Every control step replies S_OK (0x8000); the TX used ring drains
#     every submitted period (submitted == drained == 115200 B for a
#     300 ms beep); the final pcm_status is S_OK.
#   - The sound device is NOT reset by VZ at ExitBootServices
#     (snd: pre-rearm st=0f, like net/gpu).
#
# The gate asserts the device-side consumption accounting; the audible
# confirmation is the A4 composition capstone (a human hearing it).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-sound-playback.sh
#
# Evidence saved under artifacts/: live-sound-playback-gate.txt,
# live-sound-playback-report.txt, live-sound-playback-run.txt,
# live-sound-playback-serial.log, live-sound-playback-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-sound-playback-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-sound-playback-report.txt"

echo "=== verify-live-sound-playback: claim 5877 — M15 A2 PCM playback on VZ ==="

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

# The script: at the prompt, play a 440 Hz beep for 300 ms.
cat > artifacts/live-sound-playback-script.txt <<'EOF'
beep 440 300
EOF

echo "--- Phase 1: Running the A2 PCM playback on VZ (--sound, beep 440 300) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --sound \
    --script artifacts/live-sound-playback-script.txt \
    --script-expect "beep: ok" \
    --timeout 150 > artifacts/live-sound-playback-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-sound-playback-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-sound-playback-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the playback markers ---"

# Transport: the --sound attach + the not-reset-by-VZ record.
grep -q "SOUND: virtio-snd attached" artifacts/live-sound-playback-run.txt || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

grep -q "snd: pre-rearm st=0f" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: pre-rearm status line missing (expected st=0f — sound is not reset by VZ)"
    exit 1
}
echo "SND.PRE_REARM: OK (st=0x0f — not reset by VZ, like net/gpu)"

# Protocol: PCM_INFO replies OK with the observed advertisement.
grep -q "beep: info st=0x0000000000008000" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: PCM_INFO did not reply S_OK (0x8000) — the virtio-1.3 status set is not confirmed"
    exit 1
}
echo "BEEP.INFO: OK (0x8000 — virtio-1.3 status set pinned)"

grep -q "formats=0x00000000000a0020" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: PCM_INFO formats bitmap is not 0x000a0020 (S16|S32|FLOAT) — a FINDING, record the observed bitmap"
    exit 1
}
grep -q "rates=0x0000000000000480" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: PCM_INFO rates bitmap is not 0x00000480 (48000|96000) — a FINDING, record the observed bitmap"
    exit 1
}
grep -q "ch=1..2 dir=0" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: PCM_INFO did not advertise 1..2 channels OUTPUT"
    exit 1
}
echo "BEEP.TOPOLOGY: OK (S16|S32|FLOAT @ 48000|96000, 1..2 ch, OUTPUT — enumerated by asking, the A1-finding workaround)"

# Negotiation: FLOAT stereo 48 kHz accepted, prepare + start OK.
grep -q "beep: params fmt=19 rate=7 ch=2" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: negotiated params are not FLOAT(19)/48000(7)/stereo(2)"
    exit 1
}
grep -q "st=0x0000000000008000 prepare=0x0000000000008000 start=0x0000000000008000" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: SET_PARAMS/PREPARE/START did not all reply S_OK"
    exit 1
}
echo "BEEP.NEGOTIATION: OK (FLOAT/48000/stereo; SET_PARAMS+PREPARE+START all 0x8000)"

# The core proof: every submitted byte was drained by the device.
grep -q "beep: tx submitted=115200 drained=115200 frames=14400" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: the 300 ms beep accounting is not 115200 submitted / 115200 drained / 14400 frames"
    exit 1
}
grep -q "pcm_status=0x0000000000008000" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: the final TX pcm_status is not S_OK (0x8000)"
    exit 1
}
echo "BEEP.TX: OK (115200 B submitted in 4096-B periods, all drained; pcm_status 0x8000)"

# Cleanup: stop + release both S_OK.
grep -q "beep: stop=0x0000000000008000 release=0x0000000000008000" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: STOP/RELEASE did not both reply S_OK"
    exit 1
}
echo "BEEP.CLEANUP: OK (STOP + RELEASE 0x8000)"

grep -q "beep: ok" artifacts/live-sound-playback-serial.log || {
    echo "ERROR: the beep did not report ok"
    exit 1
}
echo "BEEP.OK: OK"

echo ""
echo "=== A2 sound playback gate PASSED on VZ ==="
{
    echo "verify-live-sound-playback.sh — claim 5877 (M15 A2) — PASSED"
    echo "revision: $REVISION branch=$BRANCH"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^snd:|^sound:|^beep:" artifacts/live-sound-playback-serial.log
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" artifacts/live-sound-playback-run.txt
} > "$REPORT"
cat "$REPORT"
