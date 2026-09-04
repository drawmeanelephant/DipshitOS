# live-win.spec -- vgate pilot (SPIKE runner + snapshot pixel proof):
# Driving Award desktop chrome live on VZ. Mirrors
# tools/verify-live-win.sh (milestone six, card G5): scripted registry
# exercise, keyboard-typed uname into the focused terminal, headless
# virtio snapshot decoded for terminal/taskbar/tray pixels. Proves
# runner-flags, output-contains, and snapshot asserts.

vgate_name live-win "Driving Award 4-window chrome + typed uname + pixels"
vgate_runner_flags -Xswiftc -DSPIKE
vgate_note "scripted dui registry exercise + keyboard-typed uname; raw virtio snapshot decoded"

vgate_file script.txt <<'EOF'
dui
dui hit 1000 710
dui
dui hit 10 100
dui
dui hit 100 400
EOF

vgate_run 01 -- --display --input --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-after 'dui hit: 100,400 -> 0' --snapshot-out '$RUN_DIR/snap' --script '$RUN_DIR/script.txt' --input-string "uname"$'\n' --input-string-after 'dui hit: 100,400 -> 0' --script-expect 'VirelaiOS aarch64' --timeout 60

vgate_assert 01 serial-contains 'dui: windows=4 focused=0'
vgate_assert 01 serial-contains 'dui[0]: roadpops terminal rect=0,0,1280,720'
vgate_assert 01 serial-contains 'dui[1]: wallpaper wallpaper rect=0,0,1280,720'
vgate_assert 01 serial-contains 'dui[2]: taskbar taskbar rect=0,700,1280,20'
vgate_assert 01 serial-contains 'dui[3]: dock dock rect=0,0,24,700'
vgate_assert 01 serial-contains 'dui hit: 1000,710 -> 255'
vgate_assert 01 serial-contains 'dui hit: 10,100 -> 253'
vgate_assert 01 serial-contains 'dui hit: 100,400 -> 0'
vgate_assert 01 serial-contains 'VirelaiOS aarch64'
vgate_assert 01 output-contains 'input-string: ENABLED'
vgate_assert 01 snapshot 'snap-*.raw' <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return data[k+2], data[k+1], data[k] # R, G, B

def classify(r, g, b):
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    if max(r, g, b) < 32:
        return 'terminal_bg' # terminal background (0x101418 -> ~(16,20,24))
    if r < 35 and g < 45 and b > 30 and b > r:
        return 'taskbar_bg'  # taskbar background (0x0f172a -> ~(15,23,42))
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# (a) Terminal text is rendered in the banner region
term = region(40, 10, 1200, 96, step=2)
print(f"terminal banner region: {term}")
if term.get('green', 0) < 50:
    sys.exit("FAIL: no terminal foreground in the banner region (window 0 did not render)")

# (b) Taskbar at bottom (y=700..720) has taskbar background
tb = region(100, 702, 1100, 718, step=2)
ftb = frac(tb, 'taskbar_bg')
print(f"taskbar region: {tb} taskbar_bg={ftb:.3f}")
if ftb < 0.80:
    sys.exit(f"FAIL: taskbar background not present at y=700..720 (ftb={ftb:.3f})")

# (c) Tray clock in the right 80px of taskbar (x=1200..1280, y=700..720) has taskbar bg + glyphs
tray = region(1205, 702, 1275, 718, step=1)
print(f"tray clock region: {tray}")
if tray.get('taskbar_bg', 0) == 0 or tray.get('other', 0) == 0:
    sys.exit("FAIL: tray clock does not contain expected tray content in right 80px of taskbar")

print("PASS: 4-window desktop chrome rendered with terminal, taskbar, and tray clock")
PY
