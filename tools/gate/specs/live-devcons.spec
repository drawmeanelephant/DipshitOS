# live-devcons.spec -- M22 D14: DEVCONS.BIN developer console on VZ.
# Proves typed-input path: boots with GPU, execs DEVCONS.BIN, types 'dir.bin\n',
# runs DIR.BIN child via sys_exec, decodes 8 events, and verifies rendered echo via snapshot.

vgate_name live-devcons "M22 D14: DEVCONS.BIN developer console on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec DEVCONS.BIN
EOF

vgate_file script2.txt <<'EOF'
input
procs
echo devcons-typed-sweep-done
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --via-virtio --script '$RUN_DIR/script.txt' --input-string $'dir.bin\n' --input-string-after 'devcons: settled' --script2 '$RUN_DIR/script2.txt' --script2-after 'timer heartbeat ticks=35' --screenshot-after 'timer heartbeat ticks=30' --script-expect 'devcons-typed-sweep-done' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded DEVCONS.BIN size='
vgate_assert 01 serial-contains 'devcons: open'
vgate_assert 01 serial-contains 'devcons: ready'
vgate_assert 01 serial-contains 'devcons: settled'
vgate_assert 01 serial-contains 'dir: listing /host'
vgate_assert 01 serial-contains 'dir: success'
vgate_assert 01 serial-contains 'input: armed=0 fifo=0/64 dropped=0 events=8'
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

white = 0
for y in range(100, 200, 2):
    for x in range(520, 1300, 3):
        r, g, b = px(x, y)
        if min(r, g, b) > 200:
            white += 1
print("white-glyph samples in DEVCONS log pane: %d" % white)
if white < 60:
    sys.exit("ERROR: too few white glyph pixels — the command echo was not rendered")
PY
