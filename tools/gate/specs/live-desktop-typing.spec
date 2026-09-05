# live-desktop-typing.spec -- issue #563: keys reach desktop-launched GUI app on VZ
vgate_name live-desktop-typing "issue #563: keys reach desktop-launched GUI app on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec DESKTOP.BIN
EOF

vgate_file script2.txt <<'EOF'
procs
dui
input
tasks
echo desktop-typing-sweep-done
EOF

vgate_run A -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords "down,down,down,down,down,down,down,down,down,down,return" \
    --input-chords-after "desktop: menu ready" \
    --input-string "abcde" \
    --input-string-after "edit: ready" \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "timer heartbeat ticks=35" \
    --screenshot-after "timer heartbeat ticks=30" \
    --script-expect "desktop-typing-sweep-done" \
    --timeout 150

vgate_assert A serial-contains "desktop: menu ready"
vgate_assert A serial-contains "desktop: launch EDIT.BIN pid=2"
vgate_assert A serial-contains "edit: ready"
vgate_assert A serial-contains "input: armed=0 fifo=0/64 dropped=0 events=16"
vgate_assert A serial-contains "dui: windows=6 focused=3"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert ser.count("desktop: select app") >= 10, f"fewer than 10 select-app markers: {ser.count('desktop: select app')}"
assert re.search(r'dui\[[0-9]*\]: user user rect=64,48,512,384', ser), "EDIT window rect missing"
assert "owner=2" in ser, "EDIT window owner=2 missing"
PY

vgate_assert A snapshot 'gpu-screen-after' <<'PY'
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

glyphs = 0
for y in range(155, 235, 2):
    for x in range(180, 430, 2):
        r, g, b = px(x, y)
        if min(r, g, b) > 170 or (g > 140 and r < 120 and b < 120) or (g > r + 30 and g > b + 30):
            glyphs += 1
print("glyph samples in EDIT text region: %d" % glyphs)
assert glyphs >= 50, f"too few glyph pixels: {glyphs}"
PY
