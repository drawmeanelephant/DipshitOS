# live-chrome.spec -- M20 U4 window chrome metrics + close click on VZ

vgate_name live-chrome "M20 U4 -- window chrome metrics + close click on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
echo chrome-a
EOF

vgate_file s3-A.txt <<'EOF'
echo done-a
EOF

vgate_file script-B.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui focus 0
echo chrome-b
EOF

vgate_file s3-B.txt <<'EOF'
echo done-b
EOF

vgate_file script-C.txt <<'EOF'
exec NOTEPAD.BIN
EOF

# --- boot A: FOCUSED window chrome (ring + title + close glyph) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "chrome-a" --script3-delay 25 \
    --snapshot-after "chrome-a" \
    --script-expect "done-a" --timeout 150

vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
X, Y, W, H = 56, 56, 512, 384
ok = True
for dy in (0, 1, 2):
    n = sum(1 for dx in range(8, W - 8, 16) if px(X + dx, Y + dy) == (59, 130, 246))
    ok &= n >= (W - 16) // 16 - 2
ink = sum(1 for x in range(X + 20, X + W - 40, 2) for y in range(Y + 3, Y + 16)
          if px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200)
red = sum(1 for x in range(X + W - 15, X + W - 5) for y in range(Y + 3, Y + 13)
          if px(x, y)[0] > 170 and px(x, y)[1] < 120 and px(x, y)[2] < 120)
assert ok and ink >= 30 and red >= 6, f"focused chrome failed: ok={ok} ink={ink} red={red}"
PY

# --- boot B: UNFOCUSED chrome measured edge-to-edge ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B' \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chrome-b" --script3-delay 30 \
    --snapshot-after "chrome-b" \
    --script-expect "done-b" --timeout 150

vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B snapshot 'snap-B-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
BORDER = (0x47, 0x55, 0x69)
TITLE  = (0x1a, 0x2b, 0x3c)
CLIENT = (0x18, 0x20, 0x26)
X, Y, W, H = 56, 56, 512, 384
fails = []
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
for xx in (X, X + 1, X + W - 2, X + W - 1):
    good = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(xx, yy), BORDER))
    need = len(range(Y + 20, Y + H - 6, 24))
    if good < need - 1: fails.append(f"border col {xx-X}: {good}/{need}")
third_bad = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(X + 2, yy), BORDER))
if third_bad > 2: fails.append(f"border thicker than 2px ({third_bad} hits at col+2)")
for yy in (Y + H - 2, Y + H - 1):
    good = sum(1 for xx in range(X + 8, X + W - 8, 32) if near(px(xx, yy), BORDER))
    need = len(range(X + 8, X + W - 8, 32))
    if good < need - 1: fails.append(f"border row {yy-Y}: {good}/{need}")
band = tot = 0
for yy in range(Y + 2, Y + 16):
    for xx in range(X + 4, X + W - 40, 3):
        tot += 1
        if near(px(xx, yy), TITLE): band += 1
if band < int(tot * 0.55): fails.append(f"title band bg {band}/{tot}")
ink = sum(1 for xx in range(X + 20, X + W - 40, 2) for yy in range(Y + 2, Y + 16)
          if px(xx, yy) == (255, 255, 255))
if ink < 30: fails.append(f"title label ink {ink}")
cl = sum(1 for xx in range(X + 420, X + 504, 4) for yy in range(Y + 300, Y + 372, 4)
         if near(px(xx, yy), CLIENT))
if cl < 100: fails.append(f"client bg {cl}")
red = sum(1 for xx in range(X + W - 15, X + W - 5) for yy in range(Y + 3, Y + 13)
          if px(xx, yy)[0] > 170 and px(xx, yy)[1] < 120 and px(xx, yy)[2] < 120)
if red < 6: fails.append(f"close glyph red {red}")
assert not fails, "CHROME-FAILS: " + "; ".join(fails)
PY

# --- boot C: behavioral close-click on the title-bar close glyph ---
vgate_run C -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-C.txt' \
    --pointer-virtio "320,360,c;558,64,c" --pointer-virtio-after "notepad: ready" \
    --script-expect "notepad: win_close" --timeout 150

vgate_assert C serial-contains "notepad: win_close"
vgate_assert C output-contains "PTR-CV-SEQ"
vgate_assert C serial-absent "[EXC] parking:"
