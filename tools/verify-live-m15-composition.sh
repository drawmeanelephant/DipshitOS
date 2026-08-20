#!/usr/bin/env bash
#
# verify-live-m15-composition.sh -- claim 3206 (Milestone 15, Card A4)
# class-B gate: the composition capstone on real Apple silicon VZ — the
# hearable milestone, in ONE VM session.
#
# The card: "Sound joins the desktop: a boot chime, and a sound fires on
# an existing event (window focus, a clipboard copy, or a timer tick) —
# audio composes with the M14 shared services." This gate proves all four
# layers of the milestone in a single boot:
#
#   A1 (claim 6140)  — the device: the kernel's `sound` report (DID 0x1059,
#                      class 0x040100, st=0x0f DRIVER_OK).
#   A4 (claim 3206)  — the BOOT CHIME: the kernel plays a two-tone
#                      "ding-dong" (660 Hz + 880 Hz) through the proven A2
#                      beep path the moment the transport is live — the
#                      first hearable moment of the boot.
#   A3 (claim 7636)  — the EL0 seam: CHIME.BIN execs from EL0 and drives
#                      slots 42/43 (sys_audio_info / sys_audio_play).
#   M14 S2 (7323)    — the shared service: CHIME.BIN arms a one-tick app
#                      timer (slot 40) and BLOCKS in sys_wait_event; the
#                      kernel's scheduler posts a TIMER event (kind 9, the
#                      ADR 0009 queue) and the app plays a blip in
#                      response. That is the composition: an existing
#                      event firing a sound, through the EL0 seam.
#   A2 (claim 5877)  — the playback accounting: every blip's played bytes
#                      are exact (100 ms of FLOAT/stereo/48 kHz = 4800
#                      frames = 38400 bytes, 10 chunks), and the boot
#                      chime's own beep record is the device-side drain.
#
# The app runs 3 ticks (3 seconds on VZ) and plays one 880 Hz blip per
# TIMER event. The gate asserts the chime markers, the per-tick blip
# accounting, the done marker, the exit status, and the syscalls report
# (slots 40/42/43 all counted in the same boot).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-m15-composition.sh
#
# Evidence saved under artifacts/: live-m15-composition-gate.txt,
# live-m15-composition-report.txt, live-m15-composition-run.txt,
# live-m15-composition-serial.log, live-m15-composition-script.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m15-composition-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-m15-composition-report.txt"

echo "=== verify-live-m15-composition: claim 3206 — M15 A4 composition capstone on VZ ==="

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

# The script: at the prompt, exec CHIME.BIN. It arms a one-tick timer,
# blocks, and plays a blip on every TIMER event (3 ticks, 3 blips).
cat > artifacts/live-m15-composition-script.txt <<'EOF'
exec CHIME.BIN
EOF

cat > artifacts/live-m15-composition-script2.txt <<'EOF'
sound
echo composition-live-ok
syscalls
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running CHIME.BIN on VZ (--sound, boot chime + timer-driven blips) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --sound \
    --script artifacts/live-m15-composition-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-m15-composition-script2.txt \
    --script2-after "chime: done" \
    --script-expect "composition-live-ok" \
    --timeout 150 > artifacts/live-m15-composition-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-m15-composition-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-m15-composition-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the composition markers ---"

# Host: the --sound attach.
grep -q "SOUND: virtio-snd attached" artifacts/live-m15-composition-run.txt || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# A4 boot chime: the kernel's two-tone welcome, right after the rearm.
grep -q "chime: boot chime played (660+880)" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: the boot chime did not play (marker missing):"
    grep -a "chime:\|snd: rearm" artifacts/live-m15-composition-serial.log || true
    exit 1
}
echo "BOOT.CHIME: OK (660+880 played through the A2 beep path)"

# A1 device report (the script2 `sound` command).
grep -q "sound: did=0x0000000000001059" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: device report missing DID 0x1059"
    exit 1
}
echo "DEVICE: OK (DID 0x1059)"

# A3 EL0 seam: the app learned the negotiated state before playing.
grep -q "chime: info fmt=19 rate=7 ch=2" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: sys_audio_info did not report the negotiated FLOAT/48000/stereo state"
    exit 1
}
echo "EL0.INFO: OK (fmt=19 rate=7 ch=2 — learned from the device before any play)"

# The composition: three timer-driven blips, each 100 ms of FLOAT/stereo/
# 48 kHz = 4800 frames = 38400 bytes in 10 chunks. The per-tick marker
# proves the TIMER event (the M14 shared service) FIRED the sound.
for tick in 1 2 3; do
    want="chime: tick $tick seq="
    grep -q "$want" artifacts/live-m15-composition-serial.log || {
        echo "ERROR: missing timer-tick marker: $want"
        exit 1
    }
    grep -q "chime: tick $tick seq=.* chunks=10 played=38400" artifacts/live-m15-composition-serial.log || {
        echo "ERROR: tick $tick accounting is not chunks=10 played=38400:"
        grep -a "chime: tick $tick " artifacts/live-m15-composition-serial.log
        exit 1
    }
    echo "TICK.$tick: OK (TIMER event fired the 880 Hz blip, 38400 B played)"
done

# The app finished through the real lifecycle.
grep -q "chime: done" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: CHIME.BIN did not finish (chime: done missing)"
    exit 1
}
echo "CHIME.DONE: OK"
grep -q "tasks user-exec exited status=0" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: CHIME.BIN exit status line missing"
    exit 1
}
echo "LIFECYCLE: OK (exit 0)"

# The syscalls report: slots 40/42/43 all counted in the same boot —
# sys_timer_set calls=3 (one arm per tick), sys_audio_info calls=1,
# sys_audio_play calls=30 (10 chunks × 3 blips).
grep -q "syscalls: slots=64 implemented=46" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: implemented=46 syscalls report missing from serial log"
    exit 1
}
grep -q "40 sys_timer_set calls=3" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: sys_timer_set calls=3 missing from syscalls report"
    grep -a "40 sys_timer" artifacts/live-m15-composition-serial.log || true
    exit 1
}
grep -q "42 sys_audio_info calls=1" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: sys_audio_info calls=1 missing from syscalls report"
    exit 1
}
grep -q "43 sys_audio_play calls=30" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: sys_audio_play calls=30 missing from syscalls report"
    grep -a "43 sys_audio" artifacts/live-m15-composition-serial.log || true
    exit 1
}
echo "SYSCALL COUNTS: OK (40 sys_timer_set=3, 42 sys_audio_info=1, 43 sys_audio_play=30)"

grep -q "composition-live-ok" artifacts/live-m15-composition-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

echo ""
echo "=== M15 A4 composition capstone gate PASSED on VZ ==="
{
    echo "verify-live-m15-composition.sh — claim 3206 (M15 A4) — PASSED"
    echo "revision: $REVISION branch=$BRANCH"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^chime:|^sound:|^40 sys_timer_set|^42 sys_audio_info|^43 sys_audio_play|^composition" artifacts/live-m15-composition-serial.log
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" artifacts/live-m15-composition-run.txt
} > "$REPORT"
cat "$REPORT"
