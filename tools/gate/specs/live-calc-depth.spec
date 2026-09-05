# live-calc-depth.spec -- milestone-twenty-four depth gate (claims
#
# 4354 sweep): the K2–K16 cards whose march rows were "✅ code / live gate
# pending", driven end to end on real VZ.
#
# Mechanism: boots the production image (SPIKE build, custom-virtio INPUT
# queue), execs CALC.BIN from the monitor, waits for `calc: ready`, then
# drives the GUI through the claim 9588 virtio channels and asserts the
# app's serial markers:

vgate_name live-calc-depth "milestone-twenty-four depth gate (claims"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CALC.BIN
EOF

vgate_file script2.txt <<'EOF'
echo calc-depth-live-ok
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --via-virtio --script '$RUN_DIR/script.txt' --input-chords "ctrl-s,1,comma,2,comma,3,return,escape,ctrl-d,2,0,2,6,-,0,1,-,0,1,space,-,space,2,0,2,6,-,0,1,-,1,0,return,escape,ctrl-comma,escape,r,5,s,m,ctrl-2,ctrl-u,ctrl-u,ctrl-c" --input-chords-after "calc: ready" --pointer-virtio "336,162,c;267,344,c;267,344,c;84,318,c;84,318,c;145,318,c;145,318,c" --pointer-virtio-after "calc: clip-copy" --screenshot-after "calc: deg-mode" --script2 '$RUN_DIR/script2.txt' --script2-after "calc: expr-off" --script-expect "calc-depth-live-ok" --timeout 180

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'calc: ready'
vgate_assert 01 serial-contains 'calc: stats-on'
vgate_assert 01 serial-contains 'calc: stats-ok'
vgate_assert 01 serial-contains 'calc: stats-off'
vgate_assert 01 serial-contains 'calc: date-open'
vgate_assert 01 serial-contains 'calc: date-ok'
vgate_assert 01 serial-contains 'calc: date-close'
vgate_assert 01 serial-contains 'calc: cfg-open'
vgate_assert 01 serial-contains 'calc: cfg-close'
vgate_assert 01 serial-contains 'calc: rand'
vgate_assert 01 serial-contains 'calc: mem-slot'
vgate_assert 01 serial-contains 'calc: conv-on'
vgate_assert 01 serial-contains 'calc: conv-off'
vgate_assert 01 serial-contains 'calc: clip-copy'
vgate_assert 01 serial-contains 'calc: deg-mode'
vgate_assert 01 serial-contains 'calc: rad-mode'
vgate_assert 01 serial-contains 'calc: sci-on'
vgate_assert 01 serial-contains 'calc: sci-off'
vgate_assert 01 serial-contains 'calc: expr-on'
vgate_assert 01 serial-contains 'calc: expr-off'
vgate_assert 01 serial-contains 'calc-depth-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'gpu-screen-*' <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
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
# CALC window at (48,48); display rect local (8,72,496,28) -> global
# (56,120)-(552,148) -> 2x retina (112,240)-(1104,296). The display text
# is right-aligned, so the inserted constant "3" renders in the far-right
# of the rect — sample 2x x 990..1104 for near-white glyph pixels.
white = 0
for y in range(240, 300, 2):
    for x in range(990, 1104, 3):
        r, g, b = px(x, y)
        if min(r, g, b) > 160:
            white += 1
print("white-glyph samples in CALC display (right-aligned region): %d" % white)
if white < 10:
    print("ERROR: too few white glyph pixels — display did not render the constant")
    sys.exit(1)
PY

