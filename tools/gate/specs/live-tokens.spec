# live-tokens.spec -- M37 DQ4 design tokens & cohesion

vgate_name live-tokens "M37 DQ4 design tokens & cohesion"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A0.txt <<'EOF'
settings set theme dark
settings set shadow on
exec NOTEPAD.BIN
EOF

vgate_run A0 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A0' \
    --script '$RUN_DIR/script-A0.txt' \
    --snapshot-after 'notepad: settled' \
    --script-expect 'notepad: settled' --timeout 150

vgate_assert A0 serial-contains 'notepad: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A0 serial-absent '[EXC] parking:'
vgate_assert A0 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A0', 'notepad', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(76, 60, T['title'], "title")
check(450, 78, T['bg'], "bg")
check(100, 120, T['surface'], "text surface")
check(570, 200, T['shadow'], "shadow right")
check(300, 442, T['shadow'], "shadow bottom")
PYEOF

vgate_file script-B0.txt <<'EOF'
settings set theme light
settings set shadow on
exec NOTEPAD.BIN
EOF

vgate_run B0 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B0' \
    --script '$RUN_DIR/script-B0.txt' \
    --snapshot-after 'notepad: settled' \
    --script-expect 'notepad: settled' --timeout 150

vgate_assert B0 serial-contains 'notepad: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B0 serial-absent '[EXC] parking:'
vgate_assert B0 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B0', 'notepad', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(76, 60, T['title'], "title")
check(450, 78, T['bg'], "bg")
check(100, 120, T['surface'], "text surface")
check(570, 200, T['shadow'], "shadow right")
check(300, 442, T['shadow'], "shadow bottom")
PYEOF

vgate_file script-A1.txt <<'EOF'
settings set theme dark
settings set shadow on
exec CALC.BIN
EOF

vgate_run A1 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A1' \
    --script '$RUN_DIR/script-A1.txt' \
    --snapshot-after 'calc: settled' \
    --script-expect 'calc: settled' --timeout 150

vgate_assert A1 serial-contains 'calc: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A1 serial-absent '[EXC] parking:'
vgate_assert A1 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A1', 'calc', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(68, 52, T['title'], "title")
check(100, 70, T['surface'], "history surface")
check(60, 130, T['surface'], "display surface")
majority(255, 286, T['accent'], "= accent", r=1)
check(562, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-B1.txt <<'EOF'
settings set theme light
settings set shadow on
exec CALC.BIN
EOF

vgate_run B1 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B1' \
    --script '$RUN_DIR/script-B1.txt' \
    --snapshot-after 'calc: settled' \
    --script-expect 'calc: settled' --timeout 150

vgate_assert B1 serial-contains 'calc: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B1 serial-absent '[EXC] parking:'
vgate_assert B1 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B1', 'calc', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(68, 52, T['title'], "title")
check(100, 70, T['surface'], "history surface")
check(60, 130, T['surface'], "display surface")
majority(255, 286, T['accent'], "= accent", r=1)
check(562, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-A2.txt <<'EOF'
settings set theme dark
settings set shadow on
exec EDIT.BIN
EOF

vgate_run A2 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A2' \
    --script '$RUN_DIR/script-A2.txt' \
    --snapshot-after 'edit: settled' \
    --script-expect 'edit: settled' --timeout 150

vgate_assert A2 serial-contains 'edit: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A2 serial-absent '[EXC] parking:'
vgate_assert A2 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A2', 'edit', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(84, 52, T['title'], "title")
check(80, 100, T['gutter'], "gutter")
check(200, 150, T['edit_surface'], "surface")
check(578, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-B2.txt <<'EOF'
settings set theme light
settings set shadow on
exec EDIT.BIN
EOF

vgate_run B2 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B2' \
    --script '$RUN_DIR/script-B2.txt' \
    --snapshot-after 'edit: settled' \
    --script-expect 'edit: settled' --timeout 150

vgate_assert B2 serial-contains 'edit: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B2 serial-absent '[EXC] parking:'
vgate_assert B2 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B2', 'edit', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(84, 52, T['title'], "title")
check(80, 100, T['gutter'], "gutter")
check(200, 150, T['edit_surface'], "surface")
check(578, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-A3.txt <<'EOF'
settings set theme dark
settings set shadow on
exec FILE.BIN
EOF

vgate_run A3 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A3' \
    --script '$RUN_DIR/script-A3.txt' \
    --snapshot-after 'file: settled' \
    --script-expect 'file: settled' --timeout 150

vgate_assert A3 serial-contains 'file: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A3 serial-absent '[EXC] parking:'
vgate_assert A3 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A3', 'file', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(60, 44, T['title'], "title")
check(50, 78, T['idle'], "header")
check(60, 87, T['accent'], "row0 selected")
majority(52, 366, T['accent'], "open accent", r=1)
check(554, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-B3.txt <<'EOF'
settings set theme light
settings set shadow on
exec FILE.BIN
EOF

vgate_run B3 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B3' \
    --script '$RUN_DIR/script-B3.txt' \
    --snapshot-after 'file: settled' \
    --script-expect 'file: settled' --timeout 150

vgate_assert B3 serial-contains 'file: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B3 serial-absent '[EXC] parking:'
vgate_assert B3 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B3', 'file', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(60, 44, T['title'], "title")
check(50, 78, T['idle'], "header")
check(60, 87, T['accent'], "row0 selected")
majority(52, 366, T['accent'], "open accent", r=1)
check(554, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-A4.txt <<'EOF'
settings set theme dark
settings set shadow on
exec SYSMON.BIN
EOF

vgate_run A4 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A4' \
    --script '$RUN_DIR/script-A4.txt' \
    --snapshot-after 'sysmon: settled' \
    --script-expect 'sysmon: settled' --timeout 150

vgate_assert A4 serial-contains 'sysmon: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A4 serial-absent '[EXC] parking:'
vgate_assert A4 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A4', 'sysmon', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(80, 64, T['title'], "title")
check(430, 80, T['surface'], "header surface")
check(117, 90, T['pressed'], "active tab")
check(500, 200, T['surface'], "content surface")
check(300, 435, T['bg'], "bg margin")
check(574, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-B4.txt <<'EOF'
settings set theme light
settings set shadow on
exec SYSMON.BIN
EOF

vgate_run B4 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B4' \
    --script '$RUN_DIR/script-B4.txt' \
    --snapshot-after 'sysmon: settled' \
    --script-expect 'sysmon: settled' --timeout 150

vgate_assert B4 serial-contains 'sysmon: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B4 serial-absent '[EXC] parking:'
vgate_assert B4 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B4', 'sysmon', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(80, 64, T['title'], "title")
check(430, 80, T['surface'], "header surface")
check(117, 90, T['pressed'], "active tab")
check(500, 200, T['surface'], "content surface")
check(300, 435, T['bg'], "bg margin")
check(574, 200, T['shadow'], "shadow right")
PYEOF

vgate_file script-A5.txt <<'EOF'
settings set theme dark
settings set shadow on
exec DEVCONS.BIN
EOF

vgate_run A5 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A5' \
    --script '$RUN_DIR/script-A5.txt' \
    --snapshot-after 'devcons: settled' \
    --script-expect 'devcons: settled' --timeout 150

vgate_assert A5 serial-contains 'devcons: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert A5 serial-absent '[EXC] parking:'
vgate_assert A5 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'A5', 'devcons', 'dark'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(280, 28, T['title'], "title")
check(300, 100, T['surface'], "log surface")
check(400, 272, T['muted'], "separator")
check(500, 300, T['bg'], "prompt bg")
check(662, 150, T['shadow'], "shadow right")
PYEOF

vgate_file script-B5.txt <<'EOF'
settings set theme light
settings set shadow on
exec DEVCONS.BIN
EOF

vgate_run B5 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-B5' \
    --script '$RUN_DIR/script-B5.txt' \
    --snapshot-after 'devcons: settled' \
    --script-expect 'devcons: settled' --timeout 150

vgate_assert B5 serial-contains 'devcons: tokens theme=light bg=0xf1f5f9 surface=0xffffff border=0xcbd5e1 accent=0x2563eb'
vgate_assert B5 serial-absent '[EXC] parking:'
vgate_assert B5 python <<'PYEOF'
import os, glob, sys
tag, app, theme = 'B5', 'devcons', 'light'
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
run_dir = os.environ.get("RUN_DIR", ".")
snaps = glob.glob(os.path.join(run_dir, f"snap-{tag}*.raw"))
assert snaps, f"no snap-{tag}*.raw found in {run_dir}"
path = snaps[0]
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    assert good, f"{label}: GOT {got} WANT {want}"
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    assert good, f"{label}: only {n}/25 matches"

check(280, 28, T['title'], "title")
check(300, 100, T['surface'], "log surface")
check(400, 272, T['muted'], "separator")
check(500, 300, T['bg'], "prompt bg")
check(662, 150, T['shadow'], "shadow right")
PYEOF
