# live-devcons.spec — M22 D14: DEVCONS.BIN developer console on VZ.
# Proves the typed-input path: boot with GPU, exec DEVCONS.BIN, type
# `gofiles.elf`, run that child through sys_exec, then verify its directory
# listing, clean close, decoded input events, syscall accounting, and the
# rendered command echo in the scanout.

vgate_name live-devcons "M22 D14: DEVCONS.BIN developer console on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec DEVCONS.BIN
EOF

vgate_file script2.txt <<'EOF'
dui close 3
EOF

vgate_file script3.txt <<'EOF'
input
procs
syscalls
echo devcons-typed-sweep-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
print("staged GOFILES.ELF into share (%d bytes)"
      % os.path.getsize(os.path.join(share, "GOFILES.ELF")))
PY

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --via-virtio --script '$RUN_DIR/script.txt' --input-string $'gofiles.elf\n' --input-string-after 'devcons: settled' --script2 '$RUN_DIR/script2.txt' --script2-after 'gofiles: ready' --script3 '$RUN_DIR/script3.txt' --script3-after 'gofiles OK' --screenshot-after 'gofiles OK' --script-expect 'devcons-typed-sweep-done' --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded DEVCONS.BIN size='
vgate_assert 01 serial-contains 'devcons: open'
vgate_assert 01 serial-contains 'devcons: ready'
vgate_assert 01 serial-contains 'devcons: settled'
vgate_assert 01 serial-contains 'gofiles: open id=3'
vgate_assert 01 serial-contains 'gofiles: list /host'
vgate_assert 01 serial-contains 'gofiles: entry APPS.TXT file'
vgate_assert 01 serial-contains 'gofiles: ready'
vgate_assert 01 serial-contains 'gofiles: close'
vgate_assert 01 serial-contains 'gofiles OK'
vgate_assert 01 serial-contains 'input: armed=0 fifo=0/64 dropped=0 events=12'
vgate_assert 01 serial-contains '28 sys_exec calls=1'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 snapshot 'gpu-screen*' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

# The screenshot is Retina: DEVCONS' native (260,24,400,300) window
# occupies (520,48)-(1320,648). Count contrasting pixels in that surface;
# the serial markers prove the command and child lifecycle independently.
bg = (30, 43, 58)
surface = 0
for y in range(48, 648, 4):
    for x in range(520, 1320, 4):
        r, g, b = px(x, y)
        if max(abs(r-bg[0]), abs(g-bg[1]), abs(b-bg[2])) > 24:
            surface += 1
print("contrasting samples in DEVCONS surface: %d" % surface)
if surface < 100:
    sys.exit("ERROR: too few contrasting DEVCONS surface pixels — command echo was not rendered")
PY
