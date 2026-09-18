# go-wm-hid.spec -- M63a–d (issues #1419/#1420/#1421/#1422) class-B gate:
# GOTABWM drains WM pointer/key, pin/Alt+Tab, rail-click, and drag-reorder.
#
# Seed wm=none, exec GOTABWM.ELF (explicit seat, not the boot-default path).
# SPIKE + --via-virtio. After `gotabwm: rail n=2`, `--pointer-virtio`
# `320,10,d;960,10,u`: press the unfocused cell (M63c click) and release
# over the other cell (M63d Reorder). Then `--input-chords` after the
# reorder marker so pin/Alt+Tab do not land mid-drag. No close-x, no
# pin-glyph. Do not overload go-wm-seat / go-wm-tabs.
#
# Two equal-width cells on a 1280 rail: tab 0 is [0,640) center (320,10),
# tab 1 is [640,1280) center (960,10). The last declare is focused (tab 1),
# so the drag that moves focus then flips order is 320→960. Zig's left-rail
# (158,70) is the wrong target. Pane rects include y=0; the rail wins.

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-hid-ok`, which only
# the script prints, and every stage gate waits on guest output the program
# produces (`gotabwm: win focus`, `gotabwm: rail n=2`, `gotabwm: rail-click`,
# `gotabwm: reorder `, `wm: unregistered, shim resumed`).

vgate_name go-wm-hid "issues #1419/#1420/#1421/#1422 M63a-d: GOTABWM rail drag-reorder on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec GOEDIT.ELF
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
print("staged GOEDIT.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOEDIT.ELF")))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
print("seeded %s (%d bytes)" % (seed, os.path.getsize(seed)))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,d;960,10,u' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-chords 'ctrl-shift-p,alt-tab' \
    --input-chords-after 'gotabwm: reorder ' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: rail'
vgate_assert 01 serial-contains 'gotabwm: rail n=2'
vgate_assert 01 serial-contains 'gotabwm: ptr'
vgate_assert 01 serial-contains 'gotabwm: rail-click id='
vgate_assert 01 serial-contains 'gotabwm: reorder 0->1'
vgate_assert 01 serial-contains 'gotabwm: key'
vgate_assert 01 serial-contains 'gotabwm: pin id='
vgate_assert 01 serial-contains 'gotabwm: alt-tab id='
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
rail2_re = re.compile(r"^gotabwm: rail n=2 focus=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
reorder_re = re.compile(r"^gotabwm: reorder (\d+)->(\d+)$")

def first_after(prefix):
    for i, line in enumerate(ser):
        if line.startswith(prefix):
            return i
    sys.exit("missing %s" % prefix)

def first_match(rx):
    for i, line in enumerate(ser):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/" % rx.pattern)

rail_i, rail_m = first_match(rail2_re)
click_i, click_m = first_match(click_re)
if click_i <= rail_i:
    sys.exit("rail-click must follow rail n=2 (rail@%d click@%d)" % (
        rail_i, click_i))
click_id = click_m.group(1)
if click_id == rail_m.group(1):
    sys.exit("rail-click did not move focus (still %s)" % click_id)

def first_order_after(start):
    for line in ser[start + 1:]:
        m = order_re.match(line)
        if m:
            return m
    sys.exit("no order line after index %d" % start)

click_o = first_order_after(click_i)
if click_o.group(5) != click_id:
    sys.exit("order after rail-click focus=%s want %s: %s" % (
        click_o.group(5), click_id, click_o.group(0)))
if click_o.group(1) != click_id:
    sys.exit("clicked cell 0 but order left id=%s want %s: %s" % (
        click_o.group(1), click_id, click_o.group(0)))

def first_match_after(rx, start):
    for i, line in enumerate(ser[start + 1:], start + 1):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/ after index %d" % (rx.pattern, start))

reo_i, reo_m = first_match_after(reorder_re, click_i)
if reo_m.group(1) != "0" or reo_m.group(2) != "1":
    sys.exit("HID drag must be 0->1, got %s->%s" % (
        reo_m.group(1), reo_m.group(2)))
reo_o = first_order_after(reo_i)
if (reo_o.group(1), reo_o.group(2)) != (click_o.group(2), click_o.group(1)):
    sys.exit("drag did not flip ids: click=%s drag=%s" % (
        click_o.group(0), reo_o.group(0)))

pin_i = first_after("gotabwm: pin id=")
alt_i = first_after("gotabwm: alt-tab id=")
if pin_i <= reo_i:
    sys.exit("pin must follow rail drag (reorder@%d pin@%d)" % (reo_i, pin_i))
if alt_i <= pin_i:
    sys.exit("alt-tab marker must follow pin (pin@%d alt-tab@%d)" % (pin_i, alt_i))

pin_o = first_order_after(pin_i)
alt_o = first_order_after(alt_i)
if pin_o.group(3) != "1" and pin_o.group(4) != "1":
    sys.exit("pin chord left no pin bit: %s" % pin_o.group(0))
if alt_o.group(5) == pin_o.group(5):
    sys.exit("alt-tab did not change focus (still %s): pin=%s alt=%s" % (
        pin_o.group(5), pin_o.group(0), alt_o.group(0)))
if "1" not in (alt_o.group(3), alt_o.group(4)):
    sys.exit("pin bit lost after alt-tab: %s" % alt_o.group(0))
print("rail-click id=%s (was focus %s) drag %s then pin %s then focus %s -> %s" % (
    click_id, rail_m.group(1), reo_o.group(0), pin_o.group(0),
    pin_o.group(5), alt_o.group(5)))
PY
