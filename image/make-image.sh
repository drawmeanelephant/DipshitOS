#!/usr/bin/env bash
#
# make-image.sh -- build the bootable FAT32+GPT boot disk image for DipshitOS.
#
# Usage: make-image.sh [EFI_BINARY] [IMAGE_PATH] [KERNEL_BINARY] [USER_BINARY] [COUNTER_BINARY] [PEER_BINARY] [STATUS43_BINARY] [UDP_BINARY] [WIN_BINARY] [WINCLOSE_BINARY] [WINLOOP_BINARY] [WINMOVE_BINARY] [KEYTEST_BINARY]
# Defaults: zig-out/bin/BOOTAA64.EFI   artifacts/disk.img
#           zig-out/bin/KERNEL.BIN     zig-out/bin/USER.BIN
#           zig-out/bin/COUNTER.BIN    zig-out/bin/PEER.BIN
#           zig-out/bin/STATUS43.BIN   zig-out/bin/UDP.BIN
#           zig-out/bin/WIN.BIN        zig-out/bin/WINCLOSE.BIN
#           zig-out/bin/WINLOOP.BIN    zig-out/bin/WINMOVE.BIN
#           zig-out/bin/KEYTEST.BIN
#
# USER.BIN (the milestone-three ESP user program, claim 6783), COUNTER.BIN
# (the milestone-four follow-on 2 never-exiting user program, claim 4613),
# PEER.BIN (the follow-on 3 card 3f IPC peer, claim 5965), STATUS43.BIN
# (the follow-on 4 card 4c wait-gate target, claim 9946), UDP.BIN
# (the milestone-five card N6 UDP-syscall proof, claim 1384), WIN.BIN
# (the milestone-six card G6 draw/window-syscall proof, claim 0487),
# WINCLOSE.BIN (the claim-0487 teardown follow-on release proof),
# WINLOOP.BIN (the claim-0487 ownership follow-on persistent-window proof),
# WINMOVE.BIN (the claim-0487 move/raise follow-on), and KEYTEST.BIN
# (the milestone-nine card E6 interactive event user program, claim 9328) are
# embedded at the volume root when present; the kernel's `exec` monitor
# command loads them by name from the ESP and enters them at EL0.
#
# Uses image/mkfat32.py (pure Python 3, stdlib only), so it needs no root,
# no mtools, and no loopback devices. Safe to rerun: the image is rebuilt
# from scratch every time. Fails loudly if a required tool or a compiled
# artifact is missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

EFI_BIN="${1:-$ROOT_DIR/zig-out/bin/BOOTAA64.EFI}"
IMAGE="${2:-$ROOT_DIR/artifacts/disk.img}"
KERNEL_BIN="${3:-$ROOT_DIR/zig-out/bin/KERNEL.BIN}"
USER_BIN="${4:-$ROOT_DIR/zig-out/bin/USER.BIN}"
COUNTER_BIN="${5:-$ROOT_DIR/zig-out/bin/COUNTER.BIN}"
PEER_BIN="${6:-$ROOT_DIR/zig-out/bin/PEER.BIN}"
STATUS43_BIN="${7:-$ROOT_DIR/zig-out/bin/STATUS43.BIN}"
UDP_BIN="${8:-$ROOT_DIR/zig-out/bin/UDP.BIN}"
WIN_BIN="${9:-$ROOT_DIR/zig-out/bin/WIN.BIN}"
WINCLOSE_BIN="${10:-$ROOT_DIR/zig-out/bin/WINCLOSE.BIN}"
WINLOOP_BIN="${11:-$ROOT_DIR/zig-out/bin/WINLOOP.BIN}"
WINMOVE_BIN="${12:-$ROOT_DIR/zig-out/bin/WINMOVE.BIN}"
KEYTEST_BIN="${13:-$ROOT_DIR/zig-out/bin/KEYTEST.BIN}"
SAVETEXT_BIN="${14:-$ROOT_DIR/zig-out/bin/SAVETEXT.BIN}"
TYPE_BIN="${15:-$ROOT_DIR/zig-out/bin/TYPE.BIN}"
DIR_BIN="${16:-$ROOT_DIR/zig-out/bin/DIR.BIN}"
CALC_BIN="${17:-$ROOT_DIR/zig-out/bin/CALC.BIN}"
NOTEPAD_BIN="${18:-$ROOT_DIR/zig-out/bin/NOTEPAD.BIN}"
TOP_BIN="${19:-$ROOT_DIR/zig-out/bin/TOP.BIN}"
DESKTOP_BIN="${20:-$ROOT_DIR/zig-out/bin/DESKTOP.BIN}"
TCP_BIN="${21:-$ROOT_DIR/zig-out/bin/TCP.BIN}"
FETCH_BIN="${22:-$ROOT_DIR/zig-out/bin/FETCH.BIN}"
CHAT_BIN="${23:-$ROOT_DIR/zig-out/bin/CHAT.BIN}"
FILE_BIN="${24:-$ROOT_DIR/zig-out/bin/FILE.BIN}"
FSTEST_BIN="${25:-$ROOT_DIR/zig-out/bin/FSTEST.BIN}"
TIMERTEST_BIN="${26:-$ROOT_DIR/zig-out/bin/TIMER.BIN}"
VICTIM_BIN="${27:-$ROOT_DIR/zig-out/bin/VICTIM.BIN}"
HARDEN_BIN="${28:-$ROOT_DIR/zig-out/bin/HARDEN.BIN}"
JINGLE_BIN="${29:-$ROOT_DIR/zig-out/bin/JINGLE.BIN}"
CHIME_BIN="${30:-$ROOT_DIR/zig-out/bin/CHIME.BIN}"
GLOBALS_BIN="${31:-$ROOT_DIR/zig-out/bin/GLOBALS.BIN}"
GUARD_BIN="${32:-$ROOT_DIR/zig-out/bin/GUARD.BIN}"
SPIN_BIN="${33:-$ROOT_DIR/zig-out/bin/SPIN.BIN}"
SIZE_MB="${DIPSHITOS_IMAGE_SIZE_MB:-128}"

cd "$ROOT_DIR"

fail() { echo "make-image: ERROR: $*" >&2; exit 1; }

# 1. Required tools.
command -v python3 >/dev/null 2>&1 || fail "python3 is required to build the disk image."

# 2. Compiled artifacts.
[ -f "$EFI_BIN" ] || fail "compiled EFI application not found at '$EFI_BIN' -- run 'zig build' first."
if [ "$(head -c 2 "$EFI_BIN")" != "MZ" ]; then
    fail "'$EFI_BIN' does not look like a PE/COFF image (missing MZ header)."
fi
if [ -f "$KERNEL_BIN" ]; then
    if [ "$(head -c 4 "$KERNEL_BIN")" != "DSK1" ]; then
        fail "'$KERNEL_BIN' does not start with the 'DSK1' kernel-image magic -- run 'zig build' first."
    fi
else
    fail "kernel image not found at '$KERNEL_BIN' -- run 'zig build' first (it produces zig-out/bin/KERNEL.BIN)."
fi
USER_ARGS=()
if [ -f "$USER_BIN" ]; then
    if [ "$(head -c 4 "$USER_BIN")" != "DSK1" ]; then
        fail "'$USER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/USER.BIN)."
    fi
    USER_ARGS+=("$USER_BIN")
fi
COUNTER_ARGS=()
if [ -f "$COUNTER_BIN" ]; then
    if [ "$(head -c 4 "$COUNTER_BIN")" != "DSK1" ]; then
        fail "'$COUNTER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/COUNTER.BIN)."
    fi
    COUNTER_ARGS+=("$COUNTER_BIN")
fi
PEER_ARGS=()
if [ -f "$PEER_BIN" ]; then
    if [ "$(head -c 4 "$PEER_BIN")" != "DSK1" ]; then
        fail "'$PEER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/PEER.BIN)."
    fi
    PEER_ARGS+=("$PEER_BIN")
fi
STATUS43_ARGS=()
if [ -f "$STATUS43_BIN" ]; then
    if [ "$(head -c 4 "$STATUS43_BIN")" != "DSK1" ]; then
        fail "'$STATUS43_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/STATUS43.BIN)."
    fi
    STATUS43_ARGS+=("$STATUS43_BIN")
fi
UDP_ARGS=()
if [ -f "$UDP_BIN" ]; then
    if [ "$(head -c 4 "$UDP_BIN")" != "DSK1" ]; then
        fail "'$UDP_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/UDP.BIN)."
    fi
    UDP_ARGS+=("$UDP_BIN")
fi
WIN_ARGS=()
if [ -f "$WIN_BIN" ]; then
    if [ "$(head -c 4 "$WIN_BIN")" != "DSK1" ]; then
        fail "'$WIN_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/WIN.BIN)."
    fi
    WIN_ARGS+=("$WIN_BIN")
fi
WINCLOSE_ARGS=()
if [ -f "$WINCLOSE_BIN" ]; then
    if [ "$(head -c 4 "$WINCLOSE_BIN")" != "DSK1" ]; then
        fail "'$WINCLOSE_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/WINCLOSE.BIN)."
    fi
    WINCLOSE_ARGS+=("$WINCLOSE_BIN")
fi
WINLOOP_ARGS=()
if [ -f "$WINLOOP_BIN" ]; then
    if [ "$(head -c 4 "$WINLOOP_BIN")" != "DSK1" ]; then
        fail "'$WINLOOP_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/WINLOOP.BIN)."
    fi
    WINLOOP_ARGS+=("$WINLOOP_BIN")
fi
WINMOVE_ARGS=()
if [ -f "$WINMOVE_BIN" ]; then
    if [ "$(head -c 4 "$WINMOVE_BIN")" != "DSK1" ]; then
        fail "'$WINMOVE_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/WINMOVE.BIN)."
    fi
    WINMOVE_ARGS+=("$WINMOVE_BIN")
fi
KEYTEST_ARGS=()
if [ -f "$KEYTEST_BIN" ]; then
    if [ "$(head -c 4 "$KEYTEST_BIN")" != "DSK1" ]; then
        fail "'$KEYTEST_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/KEYTEST.BIN)."
    fi
    KEYTEST_ARGS+=("$KEYTEST_BIN")
fi
SAVETEXT_ARGS=()
if [ -f "$SAVETEXT_BIN" ]; then
    if [ "$(head -c 4 "$SAVETEXT_BIN")" != "DSK1" ]; then
        fail "'$SAVETEXT_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/SAVETEXT.BIN)."
    fi
    SAVETEXT_ARGS+=("$SAVETEXT_BIN")
fi
TYPE_ARGS=()
if [ -f "$TYPE_BIN" ]; then
    if [ "$(head -c 4 "$TYPE_BIN")" != "DSK1" ]; then
        fail "'$TYPE_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/TYPE.BIN)."
    fi
    TYPE_ARGS+=("$TYPE_BIN")
fi
DIR_ARGS=()
if [ -f "$DIR_BIN" ]; then
    if [ "$(head -c 4 "$DIR_BIN")" != "DSK1" ]; then
        fail "'$DIR_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/DIR.BIN)."
    fi
    DIR_ARGS+=("$DIR_BIN")
fi
CALC_ARGS=()
if [ -f "$CALC_BIN" ]; then
    if [ "$(head -c 4 "$CALC_BIN")" != "DSK1" ]; then
        fail "'$CALC_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/CALC.BIN)."
    fi
    CALC_ARGS+=("$CALC_BIN")
fi
NOTEPAD_ARGS=()
if [ -f "$NOTEPAD_BIN" ]; then
    if [ "$(head -c 4 "$NOTEPAD_BIN")" != "DSK1" ]; then
        fail "'$NOTEPAD_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/NOTEPAD.BIN)."
    fi
    NOTEPAD_ARGS+=("$NOTEPAD_BIN")
fi
TOP_ARGS=()
if [ -f "$TOP_BIN" ]; then
    if [ "$(head -c 4 "$TOP_BIN")" != "DSK1" ]; then
        fail "'$TOP_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/TOP.BIN)."
    fi
    TOP_ARGS+=("$TOP_BIN")
fi
DESKTOP_ARGS=()
if [ -f "$DESKTOP_BIN" ]; then
    if [ "$(head -c 4 "$DESKTOP_BIN")" != "DSK1" ]; then
        fail "'$DESKTOP_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/DESKTOP.BIN)."
    fi
    DESKTOP_ARGS+=("$DESKTOP_BIN")
fi
TCP_ARGS=()
if [ -f "$TCP_BIN" ]; then
    if [ "$(head -c 4 "$TCP_BIN")" != "DSK1" ]; then
        fail "'$TCP_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/TCP.BIN)."
    fi
    TCP_ARGS+=("$TCP_BIN")
fi
FETCH_ARGS=()
if [ -f "$FETCH_BIN" ]; then
    if [ "$(head -c 4 "$FETCH_BIN")" != "DSK1" ]; then
        fail "'$FETCH_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/FETCH.BIN)."
    fi
    FETCH_ARGS+=("$FETCH_BIN")
fi
CHAT_ARGS=()
if [ -f "$CHAT_BIN" ]; then
    if [ "$(head -c 4 "$CHAT_BIN")" != "DSK1" ]; then
        fail "'$CHAT_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/CHAT.BIN)."
    fi
    CHAT_ARGS+=("$CHAT_BIN")
fi
FILE_ARGS=()
if [ -f "$FILE_BIN" ]; then
    if [ "$(head -c 4 "$FILE_BIN")" != "DSK1" ]; then
        fail "'$FILE_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/FILE.BIN)."
    fi
    FILE_ARGS+=("$FILE_BIN")
fi
FSTEST_ARGS=()
if [ -f "$FSTEST_BIN" ]; then
    if [ "$(head -c 4 "$FSTEST_BIN")" != "DSK1" ]; then
        fail "'$FSTEST_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/FSTEST.BIN)."
    fi
    FSTEST_ARGS+=("$FSTEST_BIN")
fi
TIMERTEST_ARGS=()
if [ -f "$TIMERTEST_BIN" ]; then
    if [ "$(head -c 4 "$TIMERTEST_BIN")" != "DSK1" ]; then
        fail "'$TIMERTEST_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/TIMER.BIN)."
    fi
    TIMERTEST_ARGS+=("$TIMERTEST_BIN")
fi
VICTIM_ARGS=()
if [ -f "$VICTIM_BIN" ]; then
    if [ "$(head -c 4 "$VICTIM_BIN")" != "DSK1" ]; then
        fail "'$VICTIM_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/VICTIM.BIN)."
    fi
    VICTIM_ARGS+=("$VICTIM_BIN")
fi
HARDEN_ARGS=()
if [ -f "$HARDEN_BIN" ]; then
    if [ "$(head -c 4 "$HARDEN_BIN")" != "DSK1" ]; then
        fail "'$HARDEN_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/HARDEN.BIN)."
    fi
    HARDEN_ARGS+=("$HARDEN_BIN")
fi
JINGLE_ARGS=()
if [ -f "$JINGLE_BIN" ]; then
    if [ "$(head -c 4 "$JINGLE_BIN")" != "DSK1" ]; then
        fail "'$JINGLE_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/JINGLE.BIN)."
    fi
    JINGLE_ARGS+=("$JINGLE_BIN")
fi
CHIME_ARGS=()
if [ -f "$CHIME_BIN" ]; then
    if [ "$(head -c 4 "$CHIME_BIN")" != "DSK1" ]; then
        fail "'$CHIME_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/CHIME.BIN)."
    fi
    CHIME_ARGS+=("$CHIME_BIN")
fi
# GLOBALS.BIN is the FIRST SEGMENTED image: its magic is DSK3 (milestone
# sixteen C1, claim 3805), not DSK1.
GLOBALS_ARGS=()
if [ -f "$GLOBALS_BIN" ]; then
    if [ "$(head -c 4 "$GLOBALS_BIN")" != "DSK3" ]; then
        fail "'$GLOBALS_BIN' does not start with the 'DSK3' segmented-image magic -- run 'zig build' first (it produces zig-out/bin/GLOBALS.BIN)."
    fi
    GLOBALS_ARGS+=("$GLOBALS_BIN")
fi
# GUARD.BIN is a flat DSK1 hostile program (milestone sixteen C2, claim 8403).
GUARD_ARGS=()
if [ -f "$GUARD_BIN" ]; then
    if [ "$(head -c 4 "$GUARD_BIN")" != "DSK1" ]; then
        fail "'$GUARD_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/GUARD.BIN)."
    fi
    GUARD_ARGS+=("$GUARD_BIN")
fi
# SPIN.BIN is a flat DSK1 hostile-consumer test (Arc5 issue #246).
SPIN_ARGS=()
if [ -f "$SPIN_BIN" ]; then
    if [ "$(head -c 4 "$SPIN_BIN")" != "DSK1" ]; then
        fail "'$SPIN_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/SPIN.BIN)."
    fi
    SPIN_ARGS+=("$SPIN_BIN")
fi

# SETTINGS.BIN is a flat DSK1 program (Issue #214, GUI settings panel).
# build.zig passes it as a positional but no slot consumed it before --
# restored here so the desktop's APPS.TXT-driven launcher has its app.
SETTINGS_BIN="${34:-$ROOT_DIR/zig-out/bin/SETTINGS.BIN}"
SETTINGS_ARGS=()
if [ -f "$SETTINGS_BIN" ]; then
    if [ "$(head -c 4 "$SETTINGS_BIN")" != "DSK1" ]; then
        fail "'$SETTINGS_BIN' does not start with the 'DSK1' image magic."
    fi
    SETTINGS_ARGS+=("$SETTINGS_BIN")
fi

# M22 D2 (issue #325): ASM.BIN is a flat DSK1 program (the on-machine
# AArch64 assembler).
ASM_BIN="${35:-$ROOT_DIR/zig-out/bin/ASM.BIN}"
# M22 D4 (issue #327): DISAS.BIN is a flat DSK1 program (the disassembler).
DISAS_BIN="${36:-$ROOT_DIR/zig-out/bin/DISAS.BIN}"
DISAS_ARGS=()
if [ -f "$DISAS_BIN" ]; then
    if [ "$(head -c 4 "$DISAS_BIN")" != "DSK1" ]; then
        fail "'$DISAS_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first."
    fi
    DISAS_ARGS+=("$DISAS_BIN")
fi

CRASH_BIN="${37:-$ROOT_DIR/zig-out/bin/CRASH.ELF}"
ASM_ARGS=()
if [ -f "$ASM_BIN" ]; then
    if [ "$(head -c 4 "$ASM_BIN")" != "DSK1" ]; then
        fail "'$ASM_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/ASM.BIN)."
    fi
    ASM_ARGS+=("$ASM_BIN")
fi

# M22 D3 (issue #326): CRASH.ELF — a BRK-inside-'crasher' program with a
# real symtab; generated fresh on every image build for the symbolized-
# crash gate (verify-live-symbols.sh).
CRASH_ELF="$ROOT_DIR/zig-out/bin/CRASH.ELF"
python3 "$ROOT_DIR/tools/mkhello-elf.py" --crash "$CRASH_ELF" || fail "CRASH.ELF generation failed."
if [ "$(head -c 4 "$CRASH_ELF")" != "$(printf '\x7fELF')" ]; then
    fail "'$CRASH_ELF' does not start with the ELF magic."
fi
CRASH_ARGS=("$CRASH_ELF")

# M22 D1 (issue #324): HELLO.ELF — a minimal statically linked AArch64
# ELF32 executable, generated fresh on every image build. The kernel's ELF
# loader path (`exec HELLO.ELF`, magic sniff in exec.exec_file) maps its
# single R+X PT_LOAD segment at the EL0 text aperture and runs it; the
# verify-live-elf gate asserts its sys_write marker and exit status 42.
HELLO_ELF="$ROOT_DIR/zig-out/bin/HELLO.ELF"
python3 "$ROOT_DIR/tools/mkhello-elf.py" "$HELLO_ELF" || fail "HELLO.ELF generation failed."
if [ "$(head -c 4 "$HELLO_ELF")" != "$(printf '\x7fELF')" ]; then
    fail "'$HELLO_ELF' does not start with the ELF magic."
fi

# 3. Builder script.
[ -f "$SCRIPT_DIR/mkfat32.py" ] || fail "missing $SCRIPT_DIR/mkfat32.py."

# 4. Rebuild the image from scratch (safe to rerun).
mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
echo "make-image: building FAT32+GPT image '$IMAGE' (${SIZE_MB} MiB)..."
APPS_TXT="${APPS_TXT:-$ROOT_DIR/image/apps.txt}"
APPS_TXT_ARGS=()
if [ -f "$APPS_TXT" ]; then
    APPS_TXT_ARGS+=(--apps-txt "$APPS_TXT")
fi

python3 "$SCRIPT_DIR/mkfat32.py" --size-mb "$SIZE_MB" "$IMAGE" "$EFI_BIN" "$KERNEL_BIN" "${USER_ARGS[@]}" "${COUNTER_ARGS[@]}" "${PEER_ARGS[@]}" "${STATUS43_ARGS[@]}" "${UDP_ARGS[@]}" "${WIN_ARGS[@]}" "${WINCLOSE_ARGS[@]}" "${WINLOOP_ARGS[@]}" "${WINMOVE_ARGS[@]}" "${KEYTEST_ARGS[@]}" "${SAVETEXT_ARGS[@]}" "${TYPE_ARGS[@]}" "${DIR_ARGS[@]}" "${CALC_ARGS[@]}" "${NOTEPAD_ARGS[@]}" "${TOP_ARGS[@]}" "${DESKTOP_ARGS[@]}" "${TCP_ARGS[@]+"${TCP_ARGS[@]}"}" "${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}" "${CHAT_ARGS[@]+"${CHAT_ARGS[@]}"}" "${FILE_ARGS[@]+"${FILE_ARGS[@]}"}" "${FSTEST_ARGS[@]+"${FSTEST_ARGS[@]}"}" "${TIMERTEST_ARGS[@]+"${TIMERTEST_ARGS[@]}"}" "${VICTIM_ARGS[@]+"${VICTIM_ARGS[@]}"}" "${HARDEN_ARGS[@]+"${HARDEN_ARGS[@]}"}" "${JINGLE_ARGS[@]+"${JINGLE_ARGS[@]}"}" "${CHIME_ARGS[@]+"${CHIME_ARGS[@]}"}" "${GLOBALS_ARGS[@]+"${GLOBALS_ARGS[@]}"}" "${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}" "${SPIN_ARGS[@]+"${SPIN_ARGS[@]}"}" "${SETTINGS_ARGS[@]+"${SETTINGS_ARGS[@]}"}" "${ASM_ARGS[@]+"${ASM_ARGS[@]}"}" "${DISAS_ARGS[@]+"${DISAS_ARGS[@]}"}" "${CRASH_ARGS[@]+"${CRASH_ARGS[@]}"}" "$HELLO_ELF" "${APPS_TXT_ARGS[@]}" \
    || fail "image creation failed (see output above)."

# 5. Self-verify by listing the image we just wrote.
echo "make-image: verifying image contents..."
LISTING="$(python3 "$SCRIPT_DIR/mkfat32.py" --list "$IMAGE")" \
    || fail "image verification failed."
printf '%s\n' "$LISTING"
printf '%s\n' "$LISTING" | grep -q 'KERNEL.BIN' || fail "KERNEL.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'USER.BIN' || fail "USER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'COUNTER.BIN' || fail "COUNTER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'PEER.BIN' || fail "PEER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'STATUS43.BIN' || fail "STATUS43.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'UDP.BIN' || fail "UDP.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'WIN.BIN' || fail "WIN.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'WINCLOSE.BIN' || fail "WINCLOSE.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'WINLOOP.BIN' || fail "WINLOOP.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'WINMOVE.BIN' || fail "WINMOVE.BIN missing from the image listing"
if [ -f "$KEYTEST_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'KEYTEST.BIN' || fail "KEYTEST.BIN missing from the image listing"
fi
if [ -f "$SAVETEXT_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'SAVETEXT.BIN' || fail "SAVETEXT.BIN missing from the image listing"
fi
if [ -f "$TYPE_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'TYPE.BIN' || fail "TYPE.BIN missing from the image listing"
fi
if [ -f "$DIR_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'DIR.BIN' || fail "DIR.BIN missing from the image listing"
fi
if [ -f "$CALC_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'CALC.BIN' || fail "CALC.BIN missing from the image listing"
fi
if [ -f "$NOTEPAD_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'NOTEPAD.BIN' || fail "NOTEPAD.BIN missing from the image listing"
fi
if [ -f "$TOP_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'TOP.BIN' || fail "TOP.BIN missing from the image listing"
fi
if [ -f "$DESKTOP_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'DESKTOP.BIN' || fail "DESKTOP.BIN missing from the image listing"
fi
if [ -f "$TCP_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'TCP.BIN' || fail "TCP.BIN missing from the image listing"
fi
if [ -f "$FETCH_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'FETCH.BIN' || fail "FETCH.BIN missing from the image listing"
fi
if [ -f "$CHAT_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'CHAT.BIN' || fail "CHAT.BIN missing from the image listing"
fi
if [ -f "$FILE_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'FILE.BIN' || fail "FILE.BIN missing from the image listing"
fi
if [ -f "$FSTEST_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'FSTEST.BIN' || fail "FSTEST.BIN missing from the image listing"
fi
if [ -f "$TIMERTEST_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'TIMER.BIN' || fail "TIMER.BIN missing from the image listing"
fi
if [ -f "$VICTIM_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'VICTIM.BIN' || fail "VICTIM.BIN missing from the image listing"
fi
if [ -f "$HARDEN_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'HARDEN.BIN' || fail "HARDEN.BIN missing from the image listing"
fi
if [ -f "$JINGLE_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'JINGLE.BIN' || fail "JINGLE.BIN missing from the image listing"
fi
if [ -f "$CHIME_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'CHIME.BIN' || fail "CHIME.BIN missing from the image listing"
fi
if [ -f "$GLOBALS_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'GLOBALS.BIN' || fail "GLOBALS.BIN missing from the image listing"
fi
if [ -f "$GUARD_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'GUARD.BIN' || fail "GUARD.BIN missing from the image listing"
fi
if [ -f "$SETTINGS_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'SETTINGS.BIN' || fail "SETTINGS.BIN missing from the image listing"
fi
if [ -f "$ASM_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'ASM.BIN' || fail "ASM.BIN missing from the image listing"
fi
if [ -f "$SETTINGS_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'SETTINGS.BIN' || fail "SETTINGS.BIN missing from the image listing"
fi
if [ -f "$ASM_BIN" ]; then
    printf '%s\n' "$LISTING" | grep -q 'ASM.BIN' || fail "ASM.BIN missing from the image listing"
fi
printf '%s\n' "$LISTING" | grep -q 'CRASH.ELF' || fail "CRASH.ELF missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'DISAS.BIN' || fail "DISAS.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'HELLO.ELF' || fail "HELLO.ELF missing from the image listing"

echo "make-image: done."

