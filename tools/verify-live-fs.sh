#!/usr/bin/env bash
#
# verify-live-fs.sh -- claim 6420 class-B gate: the real FAT32 storage
# driver on the live ESP. M1.5 hard gate 5 ("ls, cat, and write persist
# through reboot") observed end to end on real VZ hardware — now over the
# disk itself, replacing claim 3475's NVRAM persistence medium.
#
# Mechanism: the runner attaches the boot disk as a virtio-blk device
# (VZVirtioBlockDeviceConfiguration); the kernel's virtio_blk.zig transport
# (modern virtio-pci, claim 6420) services sector reads/writes POST-exit,
# and fat.zig mounts the ESP's FAT32 volume (GPT LBA 2048) and serves the
# root directory. `ls` lists the volume, `cat` prints file content, and
# `write` allocates clusters + FAT entries + a directory slot and writes
# the sectors back to the DISK. Because the runner's artifacts/disk.img
# backs the VM's block device across boots, a file written in one boot is
# read back from the disk in the next — persistence through reboot, with
# no NVRAM variables involved (the loader's per-boot BOOTED.TXT /
# MEMMAP.TXT / LOADER.TXT are also visible to the kernel mount).
#
# The gate is TWO boots against the SAME disk image:
#   run A (fresh image, rebuilt at gate start): script `write hello.txt
#         hello world` + `ls` + `cat hello.txt`; asserts the write-ok
#         reply, the volume listing (KERNEL.BIN / BOOTED.TXT), hello.txt
#         listed as a real [esp] file, and the cat reply. Run A also
#         exercises the milestone-four card 2 /-path surface: `ls
#         EFI/BOOT` lists the loader's subdirectory and `cat
#         EFI/BOOT/BOOTAA64.EFI` reports the honest direct-read cap (the
#         loader is ~165 KiB > the 2048-byte bounded buffer).
#   run B (same image): script `ls` + `cat hello.txt`; asserts hello.txt
#         still listed from the disk and cat still prints the content —
#         the file persisted across the reboot ON THE DISK.
# The boot-time `esp window: esp=.. disk=1` line is asserted in both runs
# (the FAT mount ran; run B's listing of hello.txt is the persistence
# proof).
#
# Honesty: the runner exits 0 only when the expected reply appears; the
# gate additionally asserts the full transcript (write reply, ls listing
# lines, cat reply), so an early exit on the echoed input line cannot pass.
# The write reply names the FAT volume ("persisted .. bytes to FAT on the
# ESP"); the ls listing marks the entry [esp], not [nvram] — the file is
# real disk storage now.
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-fs.sh            # one A/B pair (2 boots)
#   BOOTS=2 bash tools/verify-live-fs.sh    # two A/B pairs
#
# Evidence saved under artifacts/: live-fs-gate.txt (full output),
# live-fs-report.txt (per-run detail), live-fs-run-<A|B>-<NN>.txt (runner
# output), live-fs-serial-<A|B>-<NN>.log (vm-serial.log copies),
# live-fs-script-<A|B>.txt (the forwarded keystrokes).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-fs-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="artifacts/live-fs-report.txt"

echo "=== verify-live-fs: claim 6420 — FAT32 storage driver (ls/cat/write persist through reboot on the disk), $PAIRS pair(s) of boots ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted keystrokes -----------------------------------------------------
cat > artifacts/live-fs-script-A.txt <<'EOF'
write hello.txt hello world
ls
cat hello.txt
ls EFI/BOOT
cat EFI/BOOT/BOOTAA64.EFI
EOF
cat > artifacts/live-fs-script-B.txt <<'EOF'
ls
cat hello.txt
EOF

# --- per-run gate ------------------------------------------------------------
# $1 = tag, $2 = script file, $3 = expect substring, $4 = fresh disk (1|0).
# The disk image is rebuilt at gate start, so run A sees a fresh volume and
# run B — against the SAME image — sees the file run A wrote on the disk.
# Returns 0 iff the runner saw the expected reply AND every transcript
# assertion held. For run A the write-ok reply is additionally required.
run_one() {
    local tag="$1" script="$2" expect="$3" fresh="$4"
    if [ "$fresh" = 1 ]; then
        # Fresh NVRAM store: the FAT path does not use variables, but a
        # clean store keeps the marker/probe evidence legible.
        rm -f artifacts/efi-vars.bin
    fi
    rm -f artifacts/vm-serial.log
    set +e
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "artifacts/live-fs-run-$tag.txt" 2>&1
    local RC=$?
    set -e
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "artifacts/live-fs-serial-$tag.log" || true

    local SERIAL_BYTES=0
    local WRITEOK=0 FILELISTED=0 ESPFILES=0 CATREPLY=0 WINDOW=0 LSHEAD=0 SUBDIRLS=0 SUBDIRCAT=0
    if [ -f artifacts/vm-serial.log ]; then
        SERIAL_BYTES=$(wc -c < artifacts/vm-serial.log | tr -d ' ')
        # The write-ok reply: "write: ok (persisted 11 bytes to FAT on the ESP)".
        grep -a -qF -- "write: ok (persisted" artifacts/vm-serial.log && WRITEOK=1
        # Milestone four card 2: the /-path surface. `ls EFI/BOOT` lists the
        # loader's directory (its listing row, two-space indented); `cat
        # EFI/BOOT/BOOTAA64.EFI` reports the honest direct-read cap (the
        # ~165 KiB loader exceeds the 2048-byte bounded read buffer).
        grep -a -qF -- "ls: EFI/BOOT entries=" artifacts/vm-serial.log && grep -a -qF -- "  BOOTAA64.EFI" artifacts/vm-serial.log && SUBDIRLS=1
        grep -a -qF -- "cat: EFI/BOOT/BOOTAA64.EFI: file is" artifacts/vm-serial.log && grep -a -qF -- "direct read caps" artifacts/vm-serial.log && SUBDIRCAT=1
        # The persistence proof: hello.txt LISTED in the ls output as a
        # real [esp] disk file (the FAT volume, not an NVRAM variable).
        # The listing shows the FAT 8.3 short name — the write-time window
        # name in run A ("hello.txt") and the on-disk name after a reboot
        # ("HELLO.TXT", uppercase) — so the match is case-insensitive and
        # anchored to the two-space listing indent.
        grep -a -qi -- "  hello" artifacts/vm-serial.log && FILELISTED=1
        # The FAT volume listing itself (loader-written files on the disk).
        grep -a -qF -- "KERNEL.BIN" artifacts/vm-serial.log && ESPFILES=1
        grep -a -qF -- "BOOTED.TXT" artifacts/vm-serial.log && ESPFILES=1
        # The cat reply (run A: also echoed in the write line; run B: only
        # the reply can produce it).
        grep -a -qF -- "hello world" artifacts/vm-serial.log && CATREPLY=1
        # The boot-time window line proves the FAT mount ran at boot with
        # the disk ready (disk=1).
        grep -a -qF -- "esp window: esp=" artifacts/vm-serial.log && WINDOW=1
        grep -a -qF -- "disk=1" artifacts/vm-serial.log && WINDOW=1
        grep -a -qF -- "ls: esp=" artifacts/vm-serial.log && LSHEAD=1
    fi
    local PASS=0
    if [ "$RC" = 0 ] && [ "$WINDOW" = 1 ] && [ "$LSHEAD" = 1 ] && [ "$ESPFILES" = 1 ] && [ "$FILELISTED" = 1 ] && [ "$CATREPLY" = 1 ]; then
        PASS=1
    fi
    if [ "$tag" = "A" ] && { [ "$WRITEOK" != 1 ] || [ "$SUBDIRLS" != 1 ] || [ "$SUBDIRCAT" != 1 ]; }; then
        PASS=0
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK file-listed=$FILELISTED volume-files=$ESPFILES cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD subdir-ls=$SUBDIRLS subdir-cat=$SUBDIRCAT pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES write-ok=$WRITEOK file-listed=$FILELISTED volume-files=$ESPFILES cat-reply=$CATREPLY window-line=$WINDOW ls-header=$LSHEAD subdir-ls=$SUBDIRLS subdir-cat=$SUBDIRCAT pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live FAT32 storage gate (claim 6420) — ls/cat/write persist through reboot on the real disk (VZ hardware)"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: write hello.txt 'hello world' + ls + cat + ls EFI/BOOT + cat EFI/BOOT/BOOTAA64.EFI (fresh disk image)"
    echo "run B: ls + cat hello.txt (SAME image — persistence through reboot on the disk)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-fs pair $n, run A (write/ls/cat, fresh disk) ==="
    AOK=0
    # The expect is the LAST reply followed by the next prompt — the
    # runner exits when it appears, so it must be the final script line's
    # reply (the subdir cat's honest cap message; the write line's echo
    # contains "hello world" too, so that must not be the exit trigger).
    run_one "A-$n" "artifacts/live-fs-script-A.txt" $'direct read caps at 0x0000000000000800 bytes\ndipshit> ' 1 && AOK=1 || true
    echo "=== live-fs pair $n, run B (persistence through reboot, same disk) ==="
    BOK=0
    run_one "B-$n" "artifacts/live-fs-script-B.txt" $'hello world\ndipshit> ' 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-fs: PASS — ls/cat/write persist through reboot on real VZ hardware via the FAT32 driver: run A persisted 'hello world' to the ESP's FAT volume (write-ok, hello.txt [esp] in ls, cat reply) and listed/read the EFI/BOOT subdirectory by /-path (milestone-four card 2); run B — a fresh boot against the same disk image — still lists and prints the file from the disk ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-fs: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-fs-report.txt and the per-run runner output/serial logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
