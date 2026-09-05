# live-wallpaper.spec -- M33 IMG4: WND.BIN desktop wallpaper (issue #825)

vgate_name live-wallpaper "M33 IMG4: WND.BIN desktop wallpaper"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-wp.txt <<'EOF'
wnd start
EOF

vgate_file s2-wp.txt <<'EOF'
echo done-wp
EOF

vgate_run wp -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-wp' \
    --script '$RUN_DIR/script-wp.txt' \
    --snapshot-after "wnd: wallpaper present" \
    --script2 '$RUN_DIR/s2-wp.txt' --script2-after "wnd: wallpaper present" --script2-delay 1 \
    --script-expect "done-wp" --timeout 60

vgate_assert wp serial-contains "wnd: wallpaper loaded"
vgate_assert wp serial-contains "wnd: wallpaper present"
vgate_assert wp serial-absent "[EXC] parking:"

vgate_assert wp snapshot 'snap-wp-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])

WANT_BG = (30, 30, 46)

def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

bg_hits = 0
bg_total = 0
for yy in range(50, 150, 10):
    for xx in range(50, 250, 10):
        bg_total += 1
        c = px(xx, yy)
        if near(c, WANT_BG):
            bg_hits += 1

print(f"wallpaper background pixel hits: {bg_hits}/{bg_total}")
mascot_sample = px(652, 342)
print(f"mascot center sample px(652, 342): {mascot_sample}")
mascot_ok = near(mascot_sample, (170, 180, 185), tol=12)

assert bg_hits >= bg_total - 2 and mascot_ok, f"FAIL: bg_hits={bg_hits}/{bg_total}, mascot_ok={mascot_ok}"
print("WALLPAPER-PIXELS-OK")
PY
