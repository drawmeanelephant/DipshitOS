#!/usr/bin/env bash
#
# verify-live-sound-control.sh -- claim 9297 (M15 follow-up)
# class-B gate: the bounded kernel-side sound stream-state control on real
# Apple silicon VZ, in ONE VM session.
#
# The feature: a bounded stream-state control (volume 0..100 + mute),
# applied as an in-place gain at the TX submit choke point (shared by
# `beep`, the boot chime, and `sys_audio_play`), driven from the monitor
# (`sound volume <0-100>` / `sound mute <on|off>`) AND exposed through the
# EL0 seam (ADR 0007 slots 44/45 — `sys_audio_volume` / `sys_audio_mute`).
#
# This gate proves, in one boot:
#   monitor control  — `sound volume 30` sets the gain; the `sound` report
#                      shows vol=30 mute=0.
#   muted transport  — with `sound mute on`, `beep 440 200` still drains
#                      EXACTLY (76800 B in, 76800 B out, pcm_status S_OK):
#                      mute zeroes samples, it never breaks the stream.
#   unmuted path     — `sound mute off` + `beep 660 150` drains 57600 B
#                      exactly at the new volume.
#   EL0 seam         — CHIME.BIN (the A4 composition app) calls
#                      `sys_audio_volume(50)` + `sys_audio_mute(0)` and
#                      prints `chime: vol=50 mute=0`; the final `sound`
#                      report shows vol=50 mute=0 — the syscall MUTATED
#                      kernel state; the syscalls report counts 44/45.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-sound-control.sh
#
# Evidence saved under artifacts/: live-sound-control-gate.txt,
# live-sound-control-report.txt, live-sound-control-run.txt,
# live-sound-control-serial.log, live-sound-control-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-sound-control-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-sound-control-report.txt"

echo "=== verify-live-sound-control: claim 9297 — stream-state control on VZ ==="

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

# The script: drive the monitor control, beep muted + unmuted, then exec
# CHIME.BIN (the EL0 seam callers).
cat > artifacts/live-sound-control-script.txt <<'EOF'
sound volume 30
sound
sound mute on
beep 440 200
sound mute off
beep 660 150
exec CHIME.BIN
EOF

cat > artifacts/live-sound-control-script2.txt <<'EOF'
sound
syscalls
echo control-live-ok
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running the control session on VZ (--sound) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --sound \
    --script artifacts/live-sound-control-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-sound-control-script2.txt \
    --script2-after "chime: done" \
    --script-expect "control-live-ok" \
    --timeout 150 > artifacts/live-sound-control-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-sound-control-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-sound-control-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the stream-state control markers ---"

# Host: the --sound attach.
grep -q "SOUND: virtio-snd attached" artifacts/live-sound-control-run.txt || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# Monitor set + report: volume 30, unmuted.
grep -q "sound: volume=30" artifacts/live-sound-control-serial.log || {
    echo "ERROR: 'sound volume 30' did not echo the set"
    exit 1
}
echo "MONITOR.VOLUME.SET: OK (volume=30)"
grep -q "sound: vol=30 mute=0" artifacts/live-sound-control-serial.log || {
    echo "ERROR: the sound report does not show vol=30 mute=0"
    grep -a "sound: vol=" artifacts/live-sound-control-serial.log || true
    exit 1
}
echo "MONITOR.REPORT: OK (vol=30 mute=0)"

# Muted beep: the stream still drains EXACTLY (mute zeroes samples; it
# never breaks the transport or the accounting). 200 ms of FLOAT/stereo/
# 48 kHz = 9600 frames = 76800 bytes.
grep -q "sound: mute=on" artifacts/live-sound-control-serial.log || {
    echo "ERROR: 'sound mute on' did not echo"
    exit 1
}
echo "MONITOR.MUTE.ON: OK"
grep -q "beep: tx submitted=76800 drained=76800 frames=9600" artifacts/live-sound-control-serial.log || {
    echo "ERROR: the MUTED beep did not drain exactly (76800/76800):"
    grep -a "beep: tx submitted=" artifacts/live-sound-control-serial.log || true
    exit 1
}
grep -q "pcm_status=0x0000000000008000" artifacts/live-sound-control-serial.log || {
    echo "ERROR: the muted beep did not reach pcm_status S_OK"
    exit 1
}
echo "MUTED.BEEP: OK (76800 B drained exactly, pcm_status S_OK — muted, not broken)"

# Unmuted beep at the new volume: 150 ms = 7200 frames = 57600 bytes.
grep -q "sound: mute=off" artifacts/live-sound-control-serial.log || {
    echo "ERROR: 'sound mute off' did not echo"
    exit 1
}
grep -q "beep: tx submitted=57600 drained=57600 frames=7200" artifacts/live-sound-control-serial.log || {
    echo "ERROR: the unmuted beep did not drain exactly (57600/57600):"
    grep -a "beep: tx submitted=" artifacts/live-sound-control-serial.log || true
    exit 1
}
echo "UNMUTED.BEEP: OK (57600 B drained exactly at vol=30)"

# The EL0 seam: CHIME.BIN called slots 44/45 and MUTATED kernel state —
# the post-app `sound` report shows vol=50 mute=0 (CHIME set 50/unmuted).
grep -q "chime: vol=50 mute=0" artifacts/live-sound-control-serial.log || {
    echo "ERROR: CHIME.BIN did not report the EL0 volume/mute calls"
    grep -a "chime: vol" artifacts/live-sound-control-serial.log || true
    exit 1
}
echo "EL0.SEAM.CALLS: OK (chime: vol=50 mute=0)"
grep -q "chime: done" artifacts/live-sound-control-serial.log || {
    echo "ERROR: CHIME.BIN did not finish"
    exit 1
}
echo "CHIME.DONE: OK"
grep -q "tasks user-exec exited status=0" artifacts/live-sound-control-serial.log || {
    echo "ERROR: CHIME.BIN exit status line missing"
    exit 1
}
echo "LIFECYCLE: OK (exit 0)"

# The syscall MUTATED kernel state: the final report shows vol=50.
grep -q "sound: vol=50 mute=0" artifacts/live-sound-control-serial.log || {
    echo "ERROR: the post-app sound report does not show vol=50 mute=0"
    grep -a "sound: vol=" artifacts/live-sound-control-serial.log || true
    exit 1
}
echo "EL0.SEAM.STATE: OK (sys_audio_volume(50) landed in kernel state)"

# The syscalls report: implemented=46 with slots 44/45 counted.
grep -q "syscalls: slots=64 implemented=46" artifacts/live-sound-control-serial.log || {
    echo "ERROR: implemented=46 syscalls report missing from serial log"
    exit 1
}
grep -q "44 sys_audio_volume calls=1" artifacts/live-sound-control-serial.log || {
    echo "ERROR: sys_audio_volume calls=1 missing from syscalls report"
    grep -a "44 sys_audio" artifacts/live-sound-control-serial.log || true
    exit 1
}
grep -q "45 sys_audio_mute calls=1" artifacts/live-sound-control-serial.log || {
    echo "ERROR: sys_audio_mute calls=1 missing from syscalls report"
    grep -a "45 sys_audio" artifacts/live-sound-control-serial.log || true
    exit 1
}
grep -q "43 sys_audio_play calls=30" artifacts/live-sound-control-serial.log || {
    echo "ERROR: sys_audio_play calls=30 missing from syscalls report"
    exit 1
}
echo "SYSCALL COUNTS: OK (implemented=46; 44 sys_audio_volume=1, 45 sys_audio_mute=1, 43 sys_audio_play=30)"

grep -q "control-live-ok" artifacts/live-sound-control-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

echo ""
echo "=== M15 stream-state control gate PASSED on VZ ==="
{
    echo "verify-live-sound-control.sh — claim 9297 — PASSED"
    echo "revision: $REVISION branch=$BRANCH"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^sound: (volume|mute|vol|ready)|^beep: tx submitted=|^beep: pcm_status=|^chime: (info|vol|done)|^44 sys_audio_volume|^45 sys_audio_mute|^43 sys_audio_play|^control" artifacts/live-sound-control-serial.log
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" artifacts/live-sound-control-run.txt
} > "$REPORT"
cat "$REPORT"
