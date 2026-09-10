#!/usr/bin/env bash
#
# session.sh -- boot an INTERACTIVE, WINDOWED VirelaiOS desktop.
#
# This is the human front door the gate fleet never needed: the class-B/C
# gates boot a VM, drive it with scripts, assert serial evidence, and exit.
# A person who just wants to *use* the machine had to reconstruct the gate
# harness by hand. This script packages the missing pieces:
#
#   1. build the guest + image + the SPIKE runner (the host file channel
#      `--cvc-file` implies the custom-virtio device shape, which only the
#      SPIKE build declares);
#   2. seed a PERSISTENT host share (apps, APPS.TXT, wallpaper, fonts) --
#      M34/HF6 removed the apps from the disk image, so without this the
#      shell has nothing to `exec`;
#   3. boot with the GPU window + USB keyboard/pointing devices attached
#      (`--display --input`);
#   4. autostart the tabbed Sexiburger desktop via a `.virelairc` in the
#      share (delete that line, or set VIRELAI_SESSION_NO_TABWM=1, for the
#      classic floating-window WM).
#
# The canonical `artifacts/disk.img` is attached READ-ONLY through a
# throwaway ASIF overlay, so a session never mutates the shared gate image.
# User files, settings, history, and the wallpaper live in the share and
# persist between sessions.
#
# Apple silicon + macOS 27+ only (Virtualization.framework + DiskImageKit).
# This is NOT a gate and is not run in CI.
#
# Usage:
#   bash tools/session.sh            # windowed tabbed desktop
#   just session
#
# Environment:
#   VIRELAI_SESSION_SHARE=<dir>      share directory (default artifacts/session-share)
#   VIRELAI_SESSION_NO_TABWM=1       skip the tabwm autostart (floating WM)
#   VIRELAI_SESSION_SKIP_BUILD=1     skip the build step (reuse the last build)
#
# Controls: the GUI window takes real keyboard + mouse. Ctrl-C in this
# terminal ends the session. Guest serial output is written to
# artifacts/session-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SHARE="${VIRELAI_SESSION_SHARE:-$ROOT/artifacts/session-share}"
SERIAL_LOG="$ROOT/artifacts/session-serial.log"
RUNNER="host/vm-runner/.build/release/VMRunner"

# --- 1. build ---------------------------------------------------------------
if [ "${VIRELAI_SESSION_SKIP_BUILD:-0}" != "1" ]; then
    echo "session: building guest + image (zig build, zig build image)"
    zig build
    zig build image
    echo "session: building the SPIKE VMRunner (host file channel needs the custom-virtio shape)"
    swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist "$RUNNER"
fi

[ -x "$RUNNER" ] || { echo "session: ERROR — $RUNNER missing (run without VIRELAI_SESSION_SKIP_BUILD=1)"; exit 1; }
[ -f "$ROOT/artifacts/disk.img" ] || { echo "session: ERROR — artifacts/disk.img missing (run 'zig build image')"; exit 1; }

# --- 2. seed the persistent share (idempotent; never clobbers user files) ---
mkdir -p "$SHARE"

# The compiled app bundle (CALC.BIN, TABWM.BIN, LD.SO, ...).
if [ -d "$ROOT/zig-out/bin" ]; then
    cp -R "$ROOT/zig-out/bin/." "$SHARE/" 2>/dev/null || true
fi
# Freshly generated ELF fixtures (static + the M30/M31 dynamic set) so the
# dynamic apps resolve even when the last image build predates them.
if [ -f "$ROOT/tools/mkhello-elf.py" ]; then
    python3 "$ROOT/tools/mkhello-elf.py" "$SHARE/HELLO.ELF" 2>/dev/null || true
    python3 "$ROOT/tools/mkhello-elf.py" --crash "$SHARE/CRASH.ELF" 2>/dev/null || true
fi
if [ -f "$ROOT/tools/mkdyn-elf.py" ]; then
    python3 "$ROOT/tools/mkdyn-elf.py" "$SHARE" 2>/dev/null || true
fi
# Desktop manifest + wallpaper (the guest reads /host/APPS.TXT and /host/WALLPAPER.QOI).
[ -f "$ROOT/image/apps.txt" ] && cp "$ROOT/image/apps.txt" "$SHARE/APPS.TXT"
[ -f "$ROOT/image/WALLPAPER.QOI" ] && cp "$ROOT/image/WALLPAPER.QOI" "$SHARE/WALLPAPER.QOI"
# TrueType fonts (Inter for UI, Fira Code for the terminal).
[ -f "$ROOT/image/fonts/Inter-Regular.ttf" ] && cp "$ROOT/image/fonts/Inter-Regular.ttf" "$SHARE/INTER.TTF"
[ -f "$ROOT/image/fonts/FiraCode-Regular.ttf" ] && cp "$ROOT/image/fonts/FiraCode-Regular.ttf" "$SHARE/FIRACODE.TTF"

# --- 3. the session startup file (only written when absent) -----------------
RC_FILE="$SHARE/.virelairc"
if [ ! -f "$RC_FILE" ]; then
    if [ "${VIRELAI_SESSION_NO_TABWM:-0}" = "1" ]; then
        printf '%s\n' \
            '# VirelaiOS session startup. `tabwm start` boots the tabbed Sexiburger desktop;' \
            '# uncomment the next line (and remove this file to regenerate) for the floating WM.' \
            '# tabwm start' > "$RC_FILE"
    else
        printf '%s\n' \
            '# VirelaiOS session startup — edit freely. Each line runs at boot.' \
            '# `tabwm start` boots the browser-style tabbed desktop with the Sexiburger sidebar.' \
            '# Comment it out (or delete this file) to use the classic floating-window WM instead.' \
            'tabwm start' > "$RC_FILE"
    fi
fi

# --- 3b. the real clock seed ------------------------------------------------
# The guest has no RTC and the kernel has no time-of-day source, so record
# the host's LOCAL time-of-day as seconds since midnight. TABWM reads
# /host/.clock and advances it with its 1 Hz session tick (falling back to
# honest uptime when the file is absent). Rewritten every session so it is
# current at boot.
clock_secs=$(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) ))
printf '%s\n' "$clock_secs" > "$SHARE/.clock"

# --- 4. boot ----------------------------------------------------------------
# Per-run throwaway EFI variable store; the disk image stays pristine via
# --overlay-base (a fresh ASIF overlay is discarded at runner exit).
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-session.XXXXXX")"
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

cat <<EOF

>>>>>>>>>> VirelaiOS session <<<<<<<<<<

A 1280x720 VM window is opening. It boots the tabbed desktop (Sexiburger
sidebar on the left). Use the REAL keyboard + mouse in that window:

  * Ctrl+Space (or click the Sexiburger button)  open the launcher
  * type to filter, Enter launches into a new tab
  * Ctrl+Tab / Ctrl+1..9  switch tabs;  Ctrl+W closes the active tab
  * the terminal window hosts the `virelai>` shell

The guest serial log is written to artifacts/session-serial.log.
Your files persist in: $SHARE
Press Ctrl-C here to end the session.

EOF

"$RUNNER" \
    --overlay-base "$ROOT/artifacts/disk.img" --vars "$RUN_DIR/efi-vars.bin" \
    --serial "$SERIAL_LOG" \
    --cvc-file "$SHARE" \
    --display --input \
    --timeout 0
