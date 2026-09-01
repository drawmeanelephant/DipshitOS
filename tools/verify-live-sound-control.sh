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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, and scripts under $RUN_DIR per boot. Set VIRELAI_GATE_SUFFIX=_alt
# for distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the
# scratch dir.

GATE_LOG="$(art live-sound-control-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-sound-control-report.txt)"

echo "=== verify-live-sound-control: claim 9297 — stream-state control on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-sound-control
gate_seed_share
echo "run dir: $RUN_DIR"

# The script: drive the monitor control, beep muted + unmuted, then exec
# CHIME.BIN (the EL0 seam callers).
cat > "$RUN_DIR/script.txt" <<'EOF'
sound volume 30
sound
sound mute on
beep 440 200
sound mute off
beep 660 150
exec CHIME.BIN
EOF

# Sequencing (fleet remainder claim 2259, OBSERVED 2026-08-24): the
# script2 forward parks 3 s past `chime: done` — the kernel reaper is
# asynchronous and CHIME.BIN's exit lines must land inside the settle
# window (they trail `done`, and a forward typed at `done` was never
# echoed by the guest). Echo stays LAST: the runner exits on it, so the
# device + syscalls reports are fully captured first.
cat > "$RUN_DIR/script2.txt" <<'EOF'
sound
syscalls
echo control-live-ok
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running the control session on VZ (--sound) ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --sound \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "chime: done" \
    --script2-delay 3 \
    --script-expect "control-live-ok" \
    --timeout 150 > "$(art live-sound-control-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-sound-control-serial.log)" || true
SER="$(art live-sound-control-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-sound-control-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the stream-state control markers ---"

# Host: the --sound attach.
grep -q "SOUND: virtio-snd attached" "$(art live-sound-control-run.txt)" || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# Monitor set + report: volume 30, unmuted.
grep -q "sound: volume=30" "$SER" || {
    echo "ERROR: 'sound volume 30' did not echo the set"
    exit 1
}
echo "MONITOR.VOLUME.SET: OK (volume=30)"
grep -q "sound: vol=30 mute=0" "$SER" || {
    echo "ERROR: the sound report does not show vol=30 mute=0"
    grep -a "sound: vol=" "$SER" || true
    exit 1
}
echo "MONITOR.REPORT: OK (vol=30 mute=0)"

# Muted beep: the stream still drains EXACTLY (mute zeroes samples; it
# never breaks the transport or the accounting). 200 ms of FLOAT/stereo/
# 48 kHz = 9600 frames = 76800 bytes.
grep -q "sound: mute=on" "$SER" || {
    echo "ERROR: 'sound mute on' did not echo"
    exit 1
}
echo "MONITOR.MUTE.ON: OK"
grep -q "beep: tx submitted=76800 drained=76800 frames=9600" "$SER" || {
    echo "ERROR: the MUTED beep did not drain exactly (76800/76800):"
    grep -a "beep: tx submitted=" "$SER" || true
    exit 1
}
grep -q "pcm_status=0x0000000000008000" "$SER" || {
    echo "ERROR: the muted beep did not reach pcm_status S_OK"
    exit 1
}
echo "MUTED.BEEP: OK (76800 B drained exactly, pcm_status S_OK — muted, not broken)"

# Unmuted beep at the new volume: 150 ms = 7200 frames = 57600 bytes.
grep -q "sound: mute=off" "$SER" || {
    echo "ERROR: 'sound mute off' did not echo"
    exit 1
}
grep -q "beep: tx submitted=57600 drained=57600 frames=7200" "$SER" || {
    echo "ERROR: the unmuted beep did not drain exactly (57600/57600):"
    grep -a "beep: tx submitted=" "$SER" || true
    exit 1
}
echo "UNMUTED.BEEP: OK (57600 B drained exactly at vol=30)"

# The EL0 seam: CHIME.BIN called slots 44/45 and MUTATED kernel state —
# the post-app `sound` report shows vol=50 mute=0 (CHIME set 50/unmuted).
grep -q "chime: vol=50 mute=0" "$SER" || {
    echo "ERROR: CHIME.BIN did not report the EL0 volume/mute calls"
    grep -a "chime: vol" "$SER" || true
    exit 1
}
echo "EL0.SEAM.CALLS: OK (chime: vol=50 mute=0)"
grep -q "chime: done" "$SER" || {
    echo "ERROR: CHIME.BIN did not finish"
    exit 1
}
echo "CHIME.DONE: OK"
grep -q "tasks user-exec exited status=0" "$SER" || {
    echo "ERROR: CHIME.BIN exit status line missing"
    exit 1
}
echo "LIFECYCLE: OK (exit 0)"

# The syscall MUTATED kernel state: the final report shows vol=50.
grep -q "sound: vol=50 mute=0" "$SER" || {
    echo "ERROR: the post-app sound report does not show vol=50 mute=0"
    grep -a "sound: vol=" "$SER" || true
    exit 1
}
echo "EL0.SEAM.STATE: OK (sys_audio_volume(50) landed in kernel state)"

# The syscalls report — OBSERVED BYTES (2026-08-24, claim 2259):
# `implemented=61` today, not 46: slots 47-60 landed after M15 across the
# M17-M26 arcs. Slots 44/45 counted as before.
grep -q "syscalls: slots=64 implemented=61" "$SER" || {
    echo "ERROR: implemented=61 syscalls report missing from serial log"
    exit 1
}
grep -q "44 sys_audio_volume calls=1" "$SER" || {
    echo "ERROR: sys_audio_volume calls=1 missing from syscalls report"
    grep -a "44 sys_audio" "$SER" || true
    exit 1
}
grep -q "45 sys_audio_mute calls=1" "$SER" || {
    echo "ERROR: sys_audio_mute calls=1 missing from syscalls report"
    grep -a "45 sys_audio" "$SER" || true
    exit 1
}
grep -q "43 sys_audio_play calls=30" "$SER" || {
    echo "ERROR: sys_audio_play calls=30 missing from syscalls report"
    exit 1
}
echo "SYSCALL COUNTS: OK (implemented=61; 44 sys_audio_volume=1, 45 sys_audio_mute=1, 43 sys_audio_play=30)"

grep -q "control-live-ok" "$SER" || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

echo ""
echo "=== M15 stream-state control gate PASSED on VZ ==="
{
    echo "verify-live-sound-control.sh — claim 9297 — PASSED"
    DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^sound: (volume|mute|vol|ready)|^beep: tx submitted=|^beep: pcm_status=|^chime: (info|vol|done)|^44 sys_audio_volume|^45 sys_audio_mute|^43 sys_audio_play|^control" $SER
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" $(art live-sound-control-run.txt)
} > "$REPORT"
cat "$REPORT"
