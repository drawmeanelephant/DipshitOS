#!/usr/bin/env bash
#
# verify-live-gfs.sh -- claim 3678 (milestone-four card 2) class-B gate: the
# GENERAL (non-ESP) filesystem observed on real VZ hardware.
#
# The disk image (mkfat32.py, 128 MiB) carries TWO FAT32 partitions: the ESP
# (type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B at LBA 2048) and a DATA
# partition (Linux-FS type GUID 0FC63DAF-8483-4772-8E79-3D69D8477DE4, 36 MiB
# at the tail of the disk). The kernel boots the ESP as before; the new
# `mount <esp|data>` monitor command switches the active FAT volume by type
# GUID (fat.mount / fat.mount_data) and re-snapshots the window.
#
# The gate is TWO boots against the SAME disk image:
#   run A (fresh image, rebuilt at gate start): script `mount data` + `ls` +
#         `cat README.TXT` + `cat DATA.TXT` + `write hello.txt hello world`;
#         asserts the mount reply (mount: data vol_lba=..), the data volume
#         listing (README.TXT / DATA.TXT, labeled [data]), the DATA.TXT cat
#         reply, and the write-ok reply.
#   run B (same image): script `mount data` + `ls` + `cat hello.txt`;
#         asserts the data volume still lists HELLO.TXT and cat prints the
#         content — the general volume persisted across the reboot ON THE
#         DISK, independent of the ESP.
# This is the "arbitrary disk layout" + "file API beyond the ESP window"
# proof on real hardware: a second partition on the same disk, mounted by
# GUID, listed, read, written, and re-read after a reboot.
#
# Per run this reports: rc, serial-bytes, and per-assertion flags.
# Run isolation (#523 item 2 / issue #528, claim 5069): every PAIR of boots
# runs against a PRIVATE WRITABLE disk image ($RUN_DIR/disk-base.img, seeded
# fresh from artifacts/disk.img after the build), a private EFI var store,
# and private serial logs under $RUN_DIR — same shape as verify-live-fs.sh
# (the writable copy is required: run B proves run A's write persisted on
# the SAME image through a reboot). DIPSHIT_GATE_SUFFIX=_alt gives distinct
# canonical evidence names; DIPSHIT_KEEP_RUN=1 keeps the scratch dir.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-gfs.sh
#
# Evidence saved under artifacts/: live-gfs-gate.txt, live-gfs-report.txt,
# live-gfs-run-<A|B>-<NN>.txt, live-gfs-serial-<A|B>-<NN>.log,
# live-gfs-script-<A|B>.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-gfs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_shared_disk_unlock; gate_end 2>/dev/null || true; sleep 0.5' EXIT

PAIRS="${BOOTS:-1}"
REPORT="$(art live-gfs-report.txt)"

echo "=== verify-live-gfs: claim 3678 — general (non-ESP) filesystem: data partition mount + persistence on VZ, $PAIRS pair(s) of boots ==="

# --- per-run isolation -------------------------------------------------------
gate_begin live-gfs
echo "run dir: $RUN_DIR"

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
cat > "$RUN_DIR/script-A.txt" <<'EOF'
mount data
write hello.txt hello world
ls
cat README.TXT
cat DATA.TXT
EOF
cat > "$RUN_DIR/script-B.txt" <<'EOF'
mount data
ls
cat hello.txt
EOF

# --- per-run gate ------------------------------------------------------------
# $1 = tag, $2 = script file, $3 = expect substring, $4 = fresh disk (1|0).
run_one() {
    local tag="$1" script="$2" expect="$3" fresh="$4"
    if [ "$fresh" = 1 ]; then
        rm -f "$RUN_DIR/efi-vars.bin"
    fi
    rm -f "$RUN_DIR/vm-serial-$tag.log"
    set +e
    gate_shared_disk_lock
    host/vm-runner/.build/release/VMRunner artifacts/disk.img \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-expect "$expect" --timeout 40 \
        > "$(art live-gfs-run-$tag.txt)" 2>&1
    local RC=$?
    gate_shared_disk_unlock
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-gfs-serial-$tag.log)" || true
    local SER="$(art live-gfs-serial-$tag.log)"

    local SERIAL_BYTES=0
    local MOUNTOK=0 LSHEAD=0 DATAFILES=0 CATDATA=0 WRITEOK=0 FILELISTED=0 CATHELLO=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" | tr -d ' ')
        # The mount reply proves the DATA partition was discovered by type
        # GUID and mounted (the general, non-ESP volume).
        grep -a -qF -- "mount: data vol_lba=" "$SER" && MOUNTOK=1
        # The re-snapshotted window is labeled data (ls: data=N, not esp=N).
        grep -a -qF -- "ls: data=" "$SER" && LSHEAD=1
        # The data volume's own files are listed (with [data], not [esp]).
        grep -a -qF -- "  README.TXT" "$SER" && DATAFILES=1
        grep -a -qF -- "  DATA.TXT" "$SER" && DATAFILES=1
        grep -a -qF -- "  [data]" "$SER" && DATAFILES=1
        # The DATA.TXT cat reply (volume content, not the ESP's).
        grep -a -qF -- "general data volume contents" "$SER" && CATDATA=1
        # The write reply (hello world -> the DATA volume's root).
        grep -a -qF -- "write: ok (persisted" "$SER" && WRITEOK=1
        # hello.txt listed after the write (run A: window; run B: from disk).
        grep -a -qi -- "  hello" "$SER" && FILELISTED=1
        # The cat hello.txt reply.
        grep -a -qF -- "hello world" "$SER" && CATHELLO=1
    fi
    local PASS=0
    # Common requirements (both runs): the DATA volume mounted by GUID, its
    # window labeled [data] with its files listed, hello.txt listed, and the
    # hello-world cat reply. Run A additionally requires the write-ok reply
    # and the DATA.TXT cat; run B's list+cat of hello.txt are the real
    # persistence proof (run A's "hello world" match is the command echo).
    if [ "$RC" = 0 ] && [ "$MOUNTOK" = 1 ] && [ "$LSHEAD" = 1 ] && [ "$DATAFILES" = 1 ] && \
       [ "$FILELISTED" = 1 ] && [ "$CATHELLO" = 1 ]; then
        PASS=1
    fi
    if [ "$tag" = "A" ] && { [ "$WRITEOK" != 1 ] || [ "$CATDATA" != 1 ]; }; then
        PASS=0
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES mount-ok=$MOUNTOK ls-header=$LSHEAD data-files=$DATAFILES cat-data=$CATDATA write-ok=$WRITEOK file-listed=$FILELISTED cat-hello=$CATHELLO pass=$PASS"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES mount-ok=$MOUNTOK ls-header=$LSHEAD data-files=$DATAFILES cat-data=$CATDATA write-ok=$WRITEOK file-listed=$FILELISTED cat-hello=$CATHELLO pass=$PASS"
    [ "$PASS" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live general-filesystem gate (claim 3678) — the DATA partition mounted by GUID, listed, read, written, and persistent across reboot (VZ hardware)"
    echo "revision: $REVISION branch=$BRANCH pairs=$PAIRS dirty-files=$DIRTY"
    echo "run A: mount data + write hello.txt 'hello world' + ls + cat README.TXT + cat DATA.TXT (fresh disk image)"
    echo "run B: mount data + ls + cat hello.txt (SAME image — persistence through reboot on the DATA volume)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$PAIRS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-gfs pair $n, run A (mount data / write / list / read, fresh disk) ==="
    AOK=0
    # The expect is the LAST reply (the DATA.TXT cat + next prompt): the
    # runner exits when it appears, so it must be the final script line's
    # reply, not an earlier one.
    # Reply+idle-prompt anchor (colored prompt bytes; see fs gate note):
    # fires only at shell idle after the reply, so the pair's second boot
    # never reads a mid-writeback image.
    run_one "A-$n" "$RUN_DIR/script-A.txt" $'general data volume contents: 1234567890\n\x1b[32mdipshit> ' 1 && AOK=1 || true
    echo "=== live-gfs pair $n, run B (persistence through reboot, same disk) ==="
    BOK=0
    sleep 3
    run_one "B-$n" "$RUN_DIR/script-B.txt" $'hello world\n\x1b[32mdipshit> ' 0 && BOK=1 || true
    if [ "$AOK" = 1 ] && [ "$BOK" = 1 ]; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$PAIRS" ]; then
    echo "verify-live-gfs: PASS — the DATA partition (a second FAT32 volume on the same disk, Linux-FS type GUID) is mounted by GUID, its window labeled [data], its files listed and read, hello.txt written to it, and run B — a fresh boot against the same disk image — still lists and prints the file from the DATA volume ($PASS/$PAIRS pair(s))."
    echo "PASS: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-gfs: FAILED — $PASS/$PAIRS pair(s) passed; see artifacts/live-gfs-report.txt and the per-run runner output/serial logs."
    echo "FAIL: $PASS/$PAIRS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
