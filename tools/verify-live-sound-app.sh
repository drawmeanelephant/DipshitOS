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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, and scripts under $RUN_DIR per boot. Set VIRELAI_GATE_SUFFIX=_alt
# for distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the
# scratch dir.

GATE_LOG="$(art live-sound-app-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-sound-app-report.txt)"

echo "=== verify-live-sound-app: claim 7636 — M15 A3 EL0 audio seam on VZ ==="

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
gate_begin live-sound-app
gate_seed_share
echo "run dir: $RUN_DIR"

# Sequencing (claim 2259): the script2 forward parks 3 s past `jingle:
# done` so the async reap settles and the shell is back at a live prompt
# before `syscalls` is typed (a forward typed at `done` was never echoed).

# The script: at the prompt, exec JINGLE.BIN. It plays the melody and
# prints a marker per note; the syscalls report afterwards proves the
# audio slots were called from EL0.
cat > "$RUN_DIR/script.txt" <<'EOF'
exec JINGLE.BIN
EOF

# Order matters (fleet remainder claim 2259, OBSERVED 2026-08-24): the
# syscalls report must print BEFORE the success echo — the runner exits on
# the echo, so an echo-first order truncated the report and lost the
# syscall-count assertions.
cat > "$RUN_DIR/script2.txt" <<'EOF'
syscalls
echo sound-app-live-ok
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running JINGLE.BIN on VZ (--sound) ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --sound \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "jingle: done" \
    --script2-delay 3 \
    --script-expect "sound-app-live-ok" \
    --timeout 150 > "$(art live-sound-app-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-sound-app-serial.log)" || true
SER="$(art live-sound-app-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-sound-app-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the EL0 audio-seam markers ---"

# Host: the --sound attach.
grep -q "SOUND: virtio-snd attached" "$(art live-sound-app-run.txt)" || {
    echo "ERROR: runner did not report the --sound attach"
    exit 1
}
echo "SOUND.ATTACH: OK"

# App start: the negotiated state learned from the device via
# sys_audio_info (the first-call negotiation).
grep -q "jingle: info fmt=19 rate=7 ch=2" "$SER" || {
    echo "ERROR: sys_audio_info did not report the negotiated FLOAT/48000/stereo state"
    exit 1
}
grep -q "jingle: info fmt=19 rate=7 ch=2 period=4096 max=65536" "$SER" || {
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
    grep -q "$want" "$SER" || {
        echo "ERROR: missing note marker: $want"
        exit 1
    }
    grep -q "$want chunks=.* played=$4" "$SER" || {
        echo "ERROR: note $1 accounting is not played=$4:"
        grep -a "jingle: note $1 " $SER
        exit 1
    }
    echo "JINGLE.NOTE.$1: OK (f=$2 dur=$3 played=$4)"
done

# The app finished.
grep -q "jingle: done" "$SER" || {
    echo "ERROR: the melody did not finish (jingle: done missing)"
    exit 1
}
echo "JINGLE.DONE: OK"

# The syscalls report: slots 42 and 43 were called from EL0.
grep -q "42 sys_audio_info calls=1" "$SER" || {
    echo "ERROR: sys_audio_info call count is not 1"
    exit 1
}
echo "SYSCALL.INFO: OK (1 call)"
grep -q "43 sys_audio_play calls=1[4-9]\|43 sys_audio_play calls=[2-9][0-9]" "$SER" || {
    echo "ERROR: sys_audio_play was not called at least 14 times (the chunked notes)"
    grep -a "43 sys_audio_play" "$SER" || true
    exit 1
}
echo "SYSCALL.PLAY: OK (14+ calls — every note chunk was its own syscall)"

echo ""
echo "=== A3 EL0 audio seam gate PASSED on VZ ==="
{
    echo "verify-live-sound-app.sh — claim 7636 (M15 A3) — PASSED"
    DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "--- guest serial evidence ---"
    grep -aE "^jingle:|^42 sys_audio_info|^43 sys_audio_play|^sound-app" $SER
    echo ""
    echo "--- host evidence ---"
    grep -a "SOUND:" $(art live-sound-app-run.txt)
} > "$REPORT"
cat "$REPORT"
