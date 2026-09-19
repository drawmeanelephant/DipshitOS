# live-desktop-typing.spec -- issue #563: keys reach desktop-launched GUI app on VZ
#
# M60 / #1297: retargeted off Zig EDIT.BIN (deleted) onto the editor app.
# M66c (#1445): that app is NOTE.ELF now, the Go successor. One Down from the
# launcher head (GOCALC.ELF) selects it -- the launcher reads the share's
# APPS.TXT, which gate-run copies from image/apps.txt, so the selection follows
# the manifest rather than a hardcoded name. Typed glyphs must land in the
# NOTE.ELF text surface.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF
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

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run A -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords "down,return" \
    --input-chords-after "desktop: menu ready" \
    --input-string "abcde" \
    --input-string-after "note: ready" \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "timer heartbeat ticks=35" \
    --screenshot-after "timer heartbeat ticks=30" \
    --script-expect "desktop-typing-sweep-done" \
    --timeout 150

vgate_assert A serial-contains "desktop: menu ready"
vgate_assert A serial-contains "desktop: launch NOTE.ELF pid=2"
vgate_assert A serial-contains "note: ready"
vgate_assert A serial-contains "input: armed=0 fifo=0/64 dropped=0 events=7"
vgate_assert A serial-contains "dui: windows=6 focused=3"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert ser.count("desktop: select app") >= 1, f"fewer than 1 select-app markers: {ser.count('desktop: select app')}"
assert re.search(r'dui\[[0-9]*\]: user user rect=56,56,512,384', ser), "NOTE.ELF window rect missing"
assert "owner=2" in ser, "NOTE.ELF window owner=2 missing"
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

# NOTE.ELF text surface: native (6,36,244,150) inside a window at (56,56).
# NOTE.ELF keeps the Zig notepad's native 512x384 declaration (note.natW/natH),
# so this region is inherited rather than re-derived.
glyphs = 0
for y in range(90, 210, 2):
    for x in range(60, 310, 2):
        r, g, b = px(x, y)
        if min(r, g, b) > 170 or (g > 140 and r < 120 and b < 120) or (g > r + 30 and g > b + 30):
            glyphs += 1
print("glyph samples in NOTEPAD text region: %d" % glyphs)
assert glyphs >= 50, f"too few glyph pixels: {glyphs}"
PY
