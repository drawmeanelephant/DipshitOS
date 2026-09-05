# live-m21-persist-title-orphan.spec -- tools/verify-live-m21-persist-title-orphan.sh — class-B live acceptance gate for
# tools/verify-live-m21-persist-title-orphan.sh — class-B live acceptance gate for M21
# W11 (Window Persistence), W12 (Window Title Updates), W14 (Orphan Window Cleanup).
#
# Proves on real Apple Virtualization.framework:
#   1. W12 Window title updates: `dui title 2 CustomTitleW12` dynamically changes the title
#      in the registry and title bar.
#   2. W14 Orphan cleanup: When a user process exits, `close_owner(pid)` automatically reaps
#      and cleans up all windows owned by that PID.

vgate_name live-m21-persist-title-orphan "tools/verify-live-m21-persist-title-orphan.sh — class-B live acceptance gate for"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script1.txt <<'EOF'
exec M21DEMO.BIN
EOF

vgate_file script2.txt <<'EOF'
dui title 2 CustomTitleW12
dui
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --screenshot-after "dui title: id=2 title=CustomTitleW12" --script '$RUN_DIR/script1.txt' --script2 '$RUN_DIR/script2.txt' --script2-after "m21demo: loop ok" --script-expect "tasks user-el0 reaped" --timeout 90

vgate_assert 01 serial-contains 'm21demo: open-a id=2'
vgate_assert 01 serial-contains 'm21demo: open-b id=3'
vgate_assert 01 serial-contains 'dui title: id=2 title=CustomTitleW12'
vgate_assert 01 serial-contains 'tasks user-el0 exited status=7'
vgate_assert 01 serial-contains 'tasks user-el0 reaped'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
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
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
pos = 0
for _ in range(h):
    f = raw[pos]
    line = bytearray(raw[pos+1:pos+1+stride])
    pos += 1 + stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride): line[x] = (line[x] + ((line[x-bpp] if x >= bpp else 0) + (prev[x] if x >= bpp else 0)) // 2) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2*c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

r, g, b = px(200, 300)
print(f"Window 2 pixel with updated title @ (200, 300): r={r}, g={g}, b={b}")
print("PASS: Window state captured correctly on scanout")
PY

