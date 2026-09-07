# live-usb-bulk.spec -- M43 U1+U6: XHCI bulk engine + runner --usb-msd flag
#
# The first consumer of the bulk transfer engine is the raw probe itself:
# `usb bulk probe <bytes>` sends one bulk OUT with the given payload and one
# bulk IN, printing completion codes + the bytes received. The evidence is
# the wire's honest behavior — what the emulated mass-storage device does
# with arbitrary bulk bytes is recorded verbatim (the [observed] rows for
# docs/hardware-contract.md). Run 01 boots with ONLY the MSD attached (no
# --input): the bulk-only boot proves the engine end to end and the HID-only
# input arm. Run 02 boots MSD + keyboard + pointer: the HID paths report
# their usual enumeration/armed lines (the zero-regression proof — the MSD
# lives on a second controller the guest's single-controller driver doesn't
# probe; [observed]).

vgate_name live-usb-bulk "M43 U1+U6: XHCI bulk engine probe over --usb-msd"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
usb bulk
echo rx-usb-state
usb bulk probe 55 41 41 42 43
echo rx-usb-probe
usb devices
echo rx-usb-bulk
EOF

vgate_file script2.txt <<'EOF'
usb devices
usb bulk
echo rx-usb-bulk-input
EOF

vgate_setup_python <<'PY'
import os

run_dir = os.environ["RUN_DIR"]
msd = os.path.join(run_dir, "msd.img")

# The probe device is an 8 MiB MBR-partitioned disk: partition 1 = a hand-
# built minimal FAT32 volume (7 MiB at LBA 2048) + a deterministic pattern
# at LBA 1. U1 exercises the bulk pipe, not the filesystem (the U3 consumer
# card picks the content story on U2's evidence) — but the volume must be
# REAL because VZ's sniffer demands parseable disk structure.
# [observed, this spec's first runs]: VZ's disk-image sniffer REFUSES a
# fully zeroed raw image AND a bare 0x55AA MBR (VZErrorDomain Code=5 "disk
# image format is not recognized"). This host's hdiutil/newfs_msdos are
# sandbox-denied for the gate harness, so the volume is constructed in
# pure python (boot sector + FSInfo + two FATs + root dir with one file).
import struct

if os.path.exists(msd):
    os.remove(msd)

SECTOR = 512
VOL_SECTORS = 7 * 1024 * 1024 // SECTOR  # 14336
SPC = 4            # sectors per cluster
RESERVED = 32
NFATS = 2
FATSZ = 28         # sectors per FAT (3562 clusters * 4 B / 512 rounded up)
ROOT_CLUSTER = 2
DATA_START = RESERVED + NFATS * FATSZ  # sector 88

def fat32_volume():
    vol = bytearray(VOL_SECTORS * SECTOR)
    # Boot sector (BPB).
    b = bytearray(SECTOR)
    b[0:3] = b"\xeb\x3c\x90"
    b[3:11] = b"VIRELAIO"  # OEM string, exactly 8 bytes
    struct.pack_into("<H", b, 11, SECTOR)
    b[13] = SPC
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NFATS
    struct.pack_into("<H", b, 21, 0xF8)     # media descriptor at offset 21
    struct.pack_into("<I", b, 32, VOL_SECTORS)
    struct.pack_into("<I", b, 36, FATSZ)
    struct.pack_into("<I", b, 44, ROOT_CLUSTER)
    struct.pack_into("<H", b, 48, 1)        # FSInfo sector
    struct.pack_into("<H", b, 50, 6)        # backup boot sector
    b[64] = 0x80
    b[66] = 0x29                             # extended boot signature
    struct.pack_into("<I", b, 67, 0x41424344)  # volume id (deterministic)
    b[71:82] = b"USBPROBE   "  # volume label, exactly 11 bytes
    b[82:90] = b"FAT32   "
    b[510:512] = b"\x55\xaa"
    vol[0:SECTOR] = b
    # FSInfo sector.
    fs = bytearray(SECTOR)
    struct.pack_into("<I", fs, 0, 0x41615252)
    struct.pack_into("<I", fs, 484, 0x61417272)
    struct.pack_into("<I", fs, 488, 0xFFFFFFFF)  # free count (unknown)
    struct.pack_into("<I", fs, 492, 0xFFFFFFFF)  # next free
    struct.pack_into("<I", fs, 508, 0xAA550000)
    vol[1 * SECTOR : 2 * SECTOR] = fs
    # Backup boot = sector 6.
    vol[6 * SECTOR : 7 * SECTOR] = b
    # FATs: [0] = media, [1] = EOC, [2] = root EOC.
    for n in range(NFATS):
        base = (RESERVED + n * FATSZ) * SECTOR
        struct.pack_into("<I", vol, base + 0, 0x0FFFFFF8)
        struct.pack_into("<I", vol, base + 4, 0x0FFFFFFF)
        struct.pack_into("<I", vol, base + 8, 0x0FFFFFFF)  # root dir cluster
    # Root dir (cluster 2 = sector 88): volume label + PROBE.TXT.
    root = DATA_START * SECTOR
    lbl = bytearray(32)
    lbl[0:11] = b"USBPROBE   "  # exactly 11 bytes (the 8.3 label field)
    lbl[11] = 0x08
    vol[root : root + 32] = lbl
    ent = bytearray(32)
    ent[0:11] = b"PROBE   TXT"  # exactly 11 bytes (8.3: PROBE + TXT)
    ent[11] = 0x20
    struct.pack_into("<H", ent, 26, 3)       # first cluster
    struct.pack_into("<I", ent, 28, 120)     # size
    vol[root + 32 : root + 64] = ent
    # File content at cluster 3 = sector 92.
    content = b"usb-bulk-probe\n" * 8          # 120 bytes
    off = (DATA_START + SPC) * SECTOR
    vol[off : off + len(content)] = content
    return vol

img = bytearray(8 * 1024 * 1024)
vol = fat32_volume()
img[1024 * 1024 : 1024 * 1024 + len(vol)] = vol
# MBR: one partition entry (type 0x0C FAT32 LBA) covering LBA 2048..16383.
ent = bytearray(16)
ent[0] = 0x80
ent[1:4] = b"\xfe\xff\xff"
ent[4] = 0x0C
ent[5:8] = b"\xfe\xff\xff"
ent[8:12] = (2048).to_bytes(4, "little")
ent[12:16] = (14336).to_bytes(4, "little")
mbr = bytearray(512)
mbr[446:462] = ent
mbr[510:512] = b"\x55\xaa"
img[0:512] = mbr
pattern = b"M43USBMSDPROBE" + bytes(range(256)) + bytes(range(242))  # exactly 512 bytes
img[512:1024] = pattern
with open(msd, "wb") as f:
    f.write(img)
PY

# Run 01: bulk-only boot (no --input). The probe boot for the bulk engine.
vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script1.txt' --script-after "virelai>" --usb-msd '$RUN_DIR/msd.img' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The MSD enumerated as a third XHCI device with a bulk pair (the [observed]
# rows: the exact vid/pid/class + maxpkt the VZ emulation presents land in
# docs/hardware-contract.md from this gate's evidence).
vgate_assert 01 serial-contains 'usb bulk: devices='
vgate_assert 01 serial-contains 'bulk=yes'
vgate_assert 01 serial-contains 'xhci: bulk cfg out ep='
# The raw probe: the OUT/IN completion codes + received bytes, verbatim
# from the wire (no protocol above the engine in U1).
vgate_assert 01 serial-contains 'usb bulk probe: OUT cc='
vgate_assert 01 serial-contains 'usb bulk probe: IN cc='
vgate_assert 01 serial-contains 'rx-usb-probe'
# No HID device attached: the input arm must be skipped honestly (the
# bulk-only boot) — and the HID enumeration absent.
vgate_assert 01 serial-absent 'input: armed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-contains 'rx-usb-bulk'

# Run 02: MSD + keyboard + pointer. [observed, U1 run-02]: VZ gives the MSD
# its OWN XHCI controller (the HID configs don't conform to
# VZUSBDeviceConfiguration, so they can't join usbDevices) — the guest's
# single-controller driver probes the HID controller (ports 9/10) and never
# sees the MSD. Run 02 is therefore the HID zero-regression proof: the
# usual enumeration/armed lines with the second controller present.
vgate_run 02 -- --display --screen '$RUN_DIR/gpu-screen-2' --script '$RUN_DIR/script2.txt' --script-after "virelai>" --input --usb-msd '$RUN_DIR/msd.img' --timeout 90

vgate_assert 02 serial-contains 'usb: enumerated='
vgate_assert 02 serial-contains 'input: armed'
vgate_assert 02 serial-absent 'bulk=yes'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-contains 'rx-usb-bulk-input'
