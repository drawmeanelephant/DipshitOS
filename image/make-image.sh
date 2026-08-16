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

python3 "$SCRIPT_DIR/mkfat32.py" --size-mb "$SIZE_MB" "$IMAGE" "$EFI_BIN" "$KERNEL_BIN" "${USER_ARGS[@]}" "${COUNTER_ARGS[@]}" "${PEER_ARGS[@]}" "${STATUS43_ARGS[@]}" "${UDP_ARGS[@]}" "${WIN_ARGS[@]}" "${WINCLOSE_ARGS[@]}" "${WINLOOP_ARGS[@]}" "${WINMOVE_ARGS[@]}" "${KEYTEST_ARGS[@]}" "${SAVETEXT_ARGS[@]}" "${TYPE_ARGS[@]}" "${DIR_ARGS[@]}" "${CALC_ARGS[@]}" "${NOTEPAD_ARGS[@]}" "${TOP_ARGS[@]}" "${DESKTOP_ARGS[@]}" "${TCP_ARGS[@]+"${TCP_ARGS[@]}"}" "${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}" "${CHAT_ARGS[@]+"${CHAT_ARGS[@]}"}" "${APPS_TXT_ARGS[@]}" \
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

echo "make-image: done."

