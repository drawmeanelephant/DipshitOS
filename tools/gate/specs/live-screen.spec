# live-screen.spec -- claim 6053 (milestone six, card G1) class-B
#
# gate: the virtio-gpu TRANSPORT + FRAMEBUFFER observed end to end on real
# VZ — the FIRST NON-BLANK framebuffer the host `--screenshot` channel
# catches.
#
# Mechanism: the runner's `--display`/`--screenshot` flag (OFF by default —
# the default VM is untouched) attaches ONE VZVirtioGraphicsDeviceConfiguration
# with a 1280x720 scanout. The guest's virtio_gpu.zig transport (modern

vgate_name live-screen "claim 6053 (milestone six, card G1) class-B"

vgate_file script.txt <<'EOF'
screen
screen fill 00ff00
screen peek
screen
EOF

vgate_run 01 -- --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --expect "gpu: screen filled" --timeout 30

vgate_assert 01 output-contains 'gpu: pre-rearm st=00'
vgate_assert 01 output-contains 'gpu: setup ok scanout=0x0000000000000500x0x00000000000002d0'
vgate_assert 01 output-contains 'screen: did=0x0000000000001050'
vgate_assert 01 output-contains 'screen: feat=0x0000000000000000/0x0000000000000001'
vgate_assert 01 output-contains 'screen: scanout=0x0000000000000500x0x00000000000002d0 enabled=0x0000000000000001'
vgate_assert 01 output-contains 'screen: status=0x000000000000000f rearm=1 setup=1'
vgate_assert 01 output-contains 'screen: status=0x000000000000000f rearm=1 setup=1'
vgate_assert 01 output-contains 'screen fill: fill=0x000000000000ff00 transfer=ok flush=ok'
vgate_assert 01 output-contains 'screen peek: fb=0x00000000'
vgate_assert 01 output-contains 'p1=0x00000000000000ff'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'gpu-screen-*' <<'PY'
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
# Sample the terminal's text region (the top glyph rows) at a fine step
# (step 16 aliases against the 8px glyph grid and the huge dark frame
# drowns the few glyph rows — measured). The frame must be NON-BLANK:
# dark background dominant with green-family content present.
fg = 0; bg = 0; sampled = 0
for y in range(0, 96, 4):
    for x in range(0, 1024, 4):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k+1], out[k+2]
        sampled += 1
        if g > 150 and r < 160 and b < 160:
            fg += 1
        elif max(r, g, b) < 100:
            bg += 1
fg_frac = fg / sampled if sampled else 0
bg_frac = bg / sampled if sampled else 0
print(f"text region: sampled={sampled} fg={fg} ({fg_frac:.3f}) bg={bg} ({bg_frac:.3f}) — the terminal frame (Road Pops renders over the raw fill since G3)")
if bg_frac < 0.5:
    sys.exit(1)
if fg_frac < 0.01:
    sys.exit(1)
PY

