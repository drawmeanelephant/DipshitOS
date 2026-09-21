# live-tokens.spec -- M37 DQ4 design tokens & cohesion

vgate_name live-tokens "M37 DQ4 design tokens & cohesion"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# M66c / #1485: A0/B0 (exec the deleted Zig notepad) retired with it.
# The kernel theme table and its hex values stay pinned by A5/B5 (DEVCONS);
# A4/B4 (SYSMON) retired with SYSMON.BIN in M71g — see the note below.

# M60 / #1297: A2/B2 (exec EDIT.BIN) retired with the Zig editor.
# M60 / #1374: A3/B3 (exec FILE.BIN) retired with Zig FILE.BIN.
# M62h / #1406: A1/B1 (exec CALC.BIN) retired with Zig CALC.BIN. The remaining
# runs pin DEVCONS tokens.

# M71g (#1566): A4/B4 (exec SYSMON.BIN) RETIRED with SYSMON.BIN itself — the
# Zig system monitor is gone and its Go successor GOTOP.ELF paints the Go token
# table, not the Zig one, so it cannot carry a cross-language pin. Named
# coverage lost: SYSMON's own content-area pixels (its header surface, active
# tab, content surface) in dark and light. What SURVIVES, and is why this is a
# retirement rather than a gap: A5/B5 still exec a Zig app (DEVCONS.BIN), still
# assert the kernel theme table's hex values in both themes, and still scan the
# window chrome the kernel paints (title, surface, muted separator, bg, shadow)
# in dark and light — the same table the retired runs pinned.
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
