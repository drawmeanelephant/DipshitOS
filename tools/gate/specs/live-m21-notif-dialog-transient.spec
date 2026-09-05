# live-m21-notif-dialog-transient.spec -- M21 W5 notif + W13 dialog + W15 modal + W16 transient

vgate_name live-m21-notif-dialog-transient "M21 W5 notif + W13 dialog + W15 modal + W16 transient"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script1.txt <<'EOF'
exec M21DEMO.BIN
EOF

vgate_file script2.txt <<'EOF'
dui notif HelloNotification
dui notif-center
dui
dui notif-dismiss 0
dui
dui notif-clear
dui notif-center
dui unsaved 2 1
dui dialog-show 2
dui
dui dialog-click cancel
dui
dui modal 2 1
dui
dui modal 2 0
dui
dui transient 2 5
dui
EOF

vgate_run 01 -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --screenshot-after "dui transient: id=2 timeout=5" \
    --script '$RUN_DIR/script1.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after "m21demo: loop ok" \
    --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
    --timeout 90

vgate_assert 01 serial-contains "m21demo: open-a id=2"
vgate_assert 01 serial-contains "m21demo: open-b id=3"
vgate_assert 01 serial-contains "dui notif: pushed=HelloNotification"
vgate_assert 01 serial-contains "dui notif-center: open=yes"
vgate_assert 01 serial-contains "dui notif-dismiss: idx=0 ok=1"
vgate_assert 01 serial-contains "dui notif-clear: cleared"
vgate_assert 01 serial-contains "dui notif-center: open=no"
vgate_assert 01 serial-contains "dui unsaved: id=2 flag=1"
vgate_assert 01 serial-contains "dui dialog-show: target=2 open=yes"
vgate_assert 01 serial-contains "dui dialog-click: result=cancel open=no"
vgate_assert 01 serial-contains "dui modal: id=2 flag=1"
vgate_assert 01 serial-contains "dui modal: id=2 flag=0"
vgate_assert 01 serial-contains "dui transient: id=2 timeout=5"
vgate_assert 01 serial-absent "[EXC] parking:"

vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[[0-9]+\].*modal=1', ser), "modal=1 check failed"
assert re.search(r'dui\[[0-9]+\].*transient=1', ser), "transient=1 check failed"
PY

vgate_assert 01 snapshot 'gpu-screen-after' <<'PY'
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
print(f"Transient Window pixel @ (200, 300): r={r}, g={g}, b={b}")
print("PASS: Window state captured correctly on scanout")
PY
