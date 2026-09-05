# live-pointer-cg.spec -- milestone eight card U4 (claim 4993) CG
#
# follow-on (claim 3692) class-B gate: the CGEventPost pointer route drives
# pointer reports + click-to-focus, GATED on Accessibility trust.

vgate_name live-pointer-cg "milestone eight card U4 (claim 4993) CG"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

cat > /tmp/virelaios-trust-probe.swift <<'EOF'
import ApplicationServices
import CoreGraphics
print(CGPreflightPostEventAccess() && AXIsProcessTrusted() ? "1" : "0")
EOF
TRUST="$(swift /tmp/virelaios-trust-probe.swift 2>/dev/null | tail -1 || echo 0)"
rm -f /tmp/virelaios-trust-probe.swift

if [ "$TRUST" != "1" ]; then
    vgate_note "SKIP: no Accessibility trust -- the CG pointer route needs it"
    vgate_run 01 -- --timeout 1
    vgate_allow_rc 01 0 1
    vgate_assert 01 serial-absent '[EXC] parking:'
else
    vgate_file pointer-cg-script.txt <<'EOF'
dui
exec WINLOOP.BIN
dui
echo pointer-cg-ready
EOF

    PTR_SEQ="960,100;960,100,c;200,150;200,150,c;640,600;640,600,c"

    vgate_run 01 -- \
        --input --display \
        --script '$RUN_DIR/pointer-cg-script.txt' \
        --screen '$RUN_DIR/pointer-cg-screen' --screenshot-after "pointer-cg-ready" \
        --pointer "$PTR_SEQ" --pointer-after "winloop: present ok" --pointer-route cg \
        --timeout 240

    vgate_assert 01 serial-contains 'pointer-cg-ready'
    vgate_assert 01 serial-contains 'dui: pointer focus='
    vgate_assert 01 serial-contains 'ptr-reports='
    vgate_assert 01 serial-absent '[EXC] parking:'
    vgate_assert 01 snapshot 'pointer-cg-screen-after.png' <<'PY'
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

found = 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        o = y * stride + x * bpp
        r, g, b = out[o], out[o+1], out[o+2]
        if r > 140 and b > 140 and g < 110 and r - g > 60 and b - g > 60:
            found += 1
sys.exit(0 if found > 0 else 1)
PY
fi
