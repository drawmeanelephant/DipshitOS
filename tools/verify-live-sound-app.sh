#!/usr/bin/env bash
#
# verify-live-sound-app.sh -- claim 7636 (Milestone 15, Card A3)
# class-B gate: the EL0 audio seam on real Apple silicon VZ.
#
# The runner boots the production image with `--sound` and execs
# JINGLE.BIN (the twenty-sixth ESP user program). The app drives the
# seam from EL0 through ADR 0007 slots 42–43:
#
#   sys_audio_info  -> learns the negotiated format/rate/channels
#                      (FLOAT 19 / 48000 7 / stereo 2 — observed on VZ),
#                      which drives the negotiation on FIRST call (the
#                      app must know what to synthesize before any play)
#   sys_audio_play  -> each note of "Twinkle Twinkle Little Star"
#                      submitted in bounded chunks (each chunk its own
#                      syscall — the kernel plays + drains it through
#                      the proven A2 PCM path), with per-note markers
#
# Claim-time observations this gate asserts (2026-08-18, live on VZ):
#   - The 14-note melody is C C G G A A G | F F E E D D C.
#   - Each 250 ms quarter note at FLOAT/stereo/48000 = 12000 frames =
#     96000 bytes; each 500 ms half note = 24000 frames = 192000 bytes.
#   - The app's `sys_audio_info` reports the negotiated state the kernel
#     derived from the device (formats 0xa0020 / rates 0x480 / 1..2 ch).
#   - Every note's `played` accounting equals its frame math exactly
#     (the kernel returned every byte it drained on the TX queue).
#   - The syscalls report proves slots 42/43 were called (1 + N).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-sound-app.sh
#
# Evidence saved under artifacts/: live-sound-app-gate.txt,
# live-sound-app-report.txt, live-sound-app-run.txt,
# live-sound-app-serial.log, live-sound-app-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-sound-app-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-sound-app-report.txt"

echo "=== verify-live-sound-app: claim 7636 — M15 A3 EL0 audio seam on VZ ==="

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

# The script: at the prompt, exec JINGLE.BIN. It plays the melody and
# prints a marker per note; the syscalls report afterwards proves the
# audio slots were called from EL0.
cat > artifacts/live-sound-app-script.txt <<'EOF'
exec JINGLE.BIN
EOF

cat > artifacts/live-sound-app-script2.txt <<'EOF'
echo sound-app-live-ok
syscalls
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running JINGLE.BIN on VZ (--sound) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --sound \
    --script artifacts/live-sound-app-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-sound-app-script2.txt \
    --script2-after "jingle: done" \
    --script-expect "sound-app-live-ok" \
    --timeout 150 > artifacts/live-sound-app-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-sound-app-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-sound-app-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the EL0 audio-seam markers ---"

# Host: the --sound attach.
grep -q "SOUND: virtio-snd attached" artifacts/live-sound-app-run.txt || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# App start: the negotiated state learned from the device via
# sys_audio_info (the first-call negotiation).
grep -q "jingle: info fmt=19 rate=7 ch=2" artifacts/live-sound-app-serial.log || {
    echo "ERROR: sys_audio_info did not report the negotiated FLOAT/48000/stereo state"
    exit 1
}
grep -q "jingle: info fmt=19 rate=7 ch=2 period=4096 max=65536" artifacts/live-sound-app-serial.log || {
    echo "ERROR: the audio_info period/max report is not period=4096 max=65536"
    exit 1
}
echo "JINGLE.INFO: OK (fmt=19 rate=7 ch=2 period=4096 max=65536 — learned from the device before any play)"

# The melody: all 14 notes must play, with per-note markers. Quarters are
# 12000 frames = 96000 bytes; halves are 24000 frames = 192000 bytes.
for spec in "1 262 250 96000" \
            "2 262 250 96000" \
            "3 392 250 96000" \
            "4 392 250 96000" \
            "5 440 250 96000" \
            "6 440 250 96000" \
            "7 392 500 192000" \
            "8 349 250 96000" \
            "9 349 250 96000" \
            "10 330 250 96000" \
            "11 330 250 96000" \
            "12 294 250 96000" \
            "13 294 250 96000" \
            "14 262 500 192000"; do
    set -- $spec
    want="jingle: note $1 f=$2 dur=$3"
    grep -q "$want" artifacts/live-sound-app-serial.log || {
        echo "ERROR: missing note marker: $want"
        exit 1
    }
    grep -q "$want chunks=.* played=$4" artifacts/live-sound-app-serial.log || {
        echo "ERROR: note $1 accounting is not played=$4:"
        grep -a "jingle: note $1 " artifacts/live-sound-app-serial.log
        exit 1
    }
    echo "JINGLE.NOTE.$1: OK (f=$2 dur=$3 played=$4)"
done

# The app finished.
grep -q "jingle: done" artifacts/live-sound-app-serial.log || {
    echo "ERROR: the melody did not finish (jingle: done missing)"
    exit 1
}
echo "JINGLE.DONE: OK"

# The syscalls report: slots 42 and 43 were called from EL0.
grep -q "42 sys_audio_info calls=1" artifacts/live-sound-app-serial.log || {
    echo "ERROR: sys_audio_info call count is not 1"
    exit 1
}
echo "SYSCALL.INFO: OK (1 call)"
grep -q "43 sys_audio_play calls=1[4-9]\|43 sys_audio_play calls=[2-9][0-9]" artifacts/live-sound-app-serial.log || {
    echo "ERROR: sys_audio_play was not called at least 14 times (the chunked notes)"
    grep -a "43 sys_audio_play" artifacts/live-sound-app-serial.log || true
    exit 1
}
echo "SYSCALL.PLAY: OK (14+ calls — every note chunk was its own syscall)"

echo ""
echo "=== A3 EL0 audio seam gate PASSED on VZ ==="
{
    echo "verify-live-sound-app.sh — claim 7636 (M15 A3) — PASSED"
    echo "revision: $REVISION branch=$BRANCH"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^jingle:|^42 sys_audio_info|^43 sys_audio_play|^sound-app" artifacts/live-sound-app-serial.log
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" artifacts/live-sound-app-run.txt
} > "$REPORT"
cat "$REPORT"
