# go-wm-hid.spec -- M63a–e (issues #1419–#1423) class-B gate: GOTABWM HID
# capstone, plus M69c/c2 (#1530/#1535): token serial/pixel probe and the
# Ctrl+Space launcher from an honest APPS.TXT.
#
# Seed wm=none, exec GOTABWM.ELF (explicit seat, not the boot-default path).
# SPIKE + --via-virtio. Pairing is GOEDIT+GOTERM (#1405) on runs 01/02.
#
# Run 01: last declare is GOTERM (right cell, focused). After `rail n=2`,
# click `(320,10)` so TASKBAR focuses GOEDIT. `--input-string 'XYZ'` waits
# on `gotabwm: rail-click id=` (not early `goedit: present`). Chords after
# `goedit: dirty` still belong to the seat.
#
# Run 02: same pairing. `--pointer-virtio '320,10,d;960,10,u'` after
# `rail n=2` (press unfocused cell, release over the other → Reorder).
# Pin/Alt+Tab stay on run 01; this boot is the HID drag leg. go-wm-tabs
# `reorder 0->1` is M62d choreography, not this path.
#
# Run 03: seat only (no GOEDIT/GOTERM — three Go runtimes is the #1449 wall).
# `dui focus 0` after `gotabwm: win focus` supplies the M57b blur (same
# handshake as go-wm-seat). After `gotabwm: present`, Ctrl+Space opens the
# APPS.TXT launcher, type `calc` + Enter execs GOCALC.ELF as a hosted tab.
# Tokens marker pins the dark table (same shape as sysmon: tokens). A GPU
# pixel of compose-N is not what --cvc-snap returns on this seat-only boot
# (observed: 0x101418 boot fill / terminal bg). live-tokens owns window
# pixels. The catalog must not offer NOTEPAD.ELF / CALC.BIN.
#
# Two equal-width cells on a 1280 rail: tab 0 [0,640)=(320,10), tab 1
# [640,1280)=(960,10). Zig's left-rail (158,70) is the wrong target.
# Pane rects include y=0. No client-area mouse. No edit/term rewrite.

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF
#   bash tools/go/build-goterm.sh    ->  .build/go/GOTERM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- each run ends on a script-only marker
# (`rx-gotabwm-hid-ok` / `rx-gotabwm-hid-drag-ok`), and every stage gate
# waits on guest output the program produces (`gotabwm: win focus`,
# `gotabwm: rail n=2`, `gotabwm: rail-click`, `goedit: dirty`,
# `wm: unregistered, shim resumed`).

vgate_name go-wm-hid "issues #1419–#1423 M63a-e: GOTABWM type-in + HID drag on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
exec GOTERM.ELF
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-ok
EOF

vgate_file script3-drag.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-drag-ok
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
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
print("staged GOEDIT.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOEDIT.ELF")))
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
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
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-string 'XYZ' \
    --input-string-after 'gotabwm: rail-click id=' \
    --input-chords 'ctrl-s,ctrl-shift-p,alt-tab' \
    --input-chords-after 'goedit: dirty' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: rail'
vgate_assert 01 serial-contains 'gotabwm: rail n=2'
vgate_assert 01 serial-contains 'gotabwm: ptr'
vgate_assert 01 serial-contains 'gotabwm: rail-click id='
vgate_assert 01 serial-contains 'goedit: present'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'gotabwm: key'
vgate_assert 01 serial-contains 'goedit: dirty'
vgate_assert 01 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=13'
vgate_assert 01 serial-contains 'gotabwm: pin id='
vgate_assert 01 serial-contains 'gotabwm: alt-tab id='
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 01 serial-absent 'goterm: line '
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
rail2_re = re.compile(r"^gotabwm: rail n=2 focus=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
edit_re = re.compile(r"^goedit: open id=(\d+)$")
term_re = re.compile(r"^goterm: open id=(\d+)$")

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

def first_order_after(start):
    for line in ser[start + 1:]:
        m = order_re.match(line)
        if m:
            return m
    sys.exit("no order line after index %d" % start)

edit_i, edit_m = first_match(edit_re)
term_i, term_m = first_match(term_re)
rail_i, rail_m = first_match(rail2_re)
click_i, click_m = first_match(click_re)
if click_i <= rail_i:
    sys.exit("rail-click must follow rail n=2 (rail@%d click@%d)" % (
        rail_i, click_i))
click_id = click_m.group(1)
edit_id = edit_m.group(1)
term_id = term_m.group(1)
if click_id != edit_id:
    sys.exit("rail-click id=%s is not GOEDIT id=%s (GOTERM id=%s)" % (
        click_id, edit_id, term_id))
if click_id == term_id:
    sys.exit("rail-click focused GOTERM id=%s" % term_id)
if click_id == rail_m.group(1):
    sys.exit("rail-click did not move focus (still %s)" % click_id)

click_o = first_order_after(click_i)
if click_o.group(5) != click_id:
    sys.exit("order after rail-click focus=%s want %s: %s" % (
        click_o.group(5), click_id, click_o.group(0)))
if click_o.group(1) != click_id:
    sys.exit("clicked cell 0 but order left id=%s want %s: %s" % (
        click_o.group(1), click_id, click_o.group(0)))

dirty_i = first_after("goedit: dirty")
if dirty_i <= click_i:
    sys.exit("goedit: dirty must follow rail-click (click@%d dirty@%d)" % (
        click_i, dirty_i))
saved_i = first_after("goedit: saved /host/EDIT/SEED.TXT n=13")
if saved_i <= dirty_i:
    sys.exit("goedit: saved must follow dirty (dirty@%d saved@%d)" % (
        dirty_i, saved_i))

pin_i = first_after("gotabwm: pin id=")
alt_i = first_after("gotabwm: alt-tab id=")
if pin_i <= saved_i:
    sys.exit("pin must follow GOEDIT save (saved@%d pin@%d)" % (saved_i, pin_i))
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

share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "SEED.TXT")
want = b"seed-line\nXYZ"
got = open(path, "rb").read()
if got != want:
    sys.exit("SAVED CONTENT MISMATCH: got %r want %r" % (got, want))
print("rail-click GOEDIT id=%s (was focus %s) dirty then saved %r then pin %s then focus %s -> %s" % (
    click_id, rail_m.group(1), got, pin_o.group(0), pin_o.group(5), alt_o.group(5)))
PY

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,d;960,10,u' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --script3 '$RUN_DIR/script3-drag.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-drag-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: rail n=2'
vgate_assert 02 serial-contains 'gotabwm: ptr'
vgate_assert 02 serial-contains 'gotabwm: rail-click id='
vgate_assert 02 serial-contains 'gotabwm: reorder 0->1'
vgate_assert 02 serial-contains 'gotabwm: close'
vgate_assert 02 serial-contains 'gotabwm OK'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'rx-gotabwm-hid-drag-ok'
vgate_assert 02 serial-absent 'goterm: line '
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
rail2_re = re.compile(r"^gotabwm: rail n=2 focus=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
reorder_re = re.compile(r"^gotabwm: reorder (\d+)->(\d+)$")

def first_match(rx):
    for i, line in enumerate(ser):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/" % rx.pattern)

def first_order_after(start):
    for line in ser[start + 1:]:
        m = order_re.match(line)
        if m:
            return m
    sys.exit("no order line after index %d" % start)

def first_match_after(rx, start):
    for i, line in enumerate(ser[start + 1:], start + 1):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/ after index %d" % (rx.pattern, start))

rail_i, rail_m = first_match(rail2_re)
click_i, click_m = first_match(click_re)
if click_i <= rail_i:
    sys.exit("rail-click must follow rail n=2 (rail@%d click@%d)" % (
        rail_i, click_i))
click_id = click_m.group(1)
if click_id == rail_m.group(1):
    sys.exit("rail-click did not move focus (still %s)" % click_id)

click_o = first_order_after(click_i)
if click_o.group(5) != click_id:
    sys.exit("order after rail-click focus=%s want %s: %s" % (
        click_o.group(5), click_id, click_o.group(0)))
if click_o.group(1) != click_id:
    sys.exit("clicked cell 0 but order left id=%s want %s: %s" % (
        click_o.group(1), click_id, click_o.group(0)))

reo_i, reo_m = first_match_after(reorder_re, click_i)
if reo_m.group(1) != "0" or reo_m.group(2) != "1":
    sys.exit("HID drag must be 0->1, got %s->%s" % (
        reo_m.group(1), reo_m.group(2)))
reo_o = first_order_after(reo_i)
if (reo_o.group(1), reo_o.group(2)) != (click_o.group(2), click_o.group(1)):
    sys.exit("drag did not flip ids: click=%s drag=%s" % (
        click_o.group(0), reo_o.group(0)))
print("HID drag rail-click id=%s (was focus %s) flip %s" % (
    click_id, rail_m.group(1), reo_o.group(0)))
PY

vgate_file script2-launch.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-launch.txt <<'EOF'
wm
dui
echo rx-gotabwm-launch-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-launch.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-space,c,a,l,c,return' \
    --input-chords-after 'gotabwm: present' \
    --script3 '$RUN_DIR/script3-launch.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-launch-ok' --timeout 300

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert 03 serial-contains 'gotabwm: present'
vgate_assert 03 serial-contains 'gotabwm: launcher open n='
vgate_assert 03 serial-contains 'gotabwm: launcher filter q=calc n='
vgate_assert 03 serial-contains 'gotabwm: launcher exec GOCALC.ELF'
vgate_assert 03 serial-contains 'gotabwm: launcher dismiss'
vgate_assert 03 serial-contains 'gocalc: declare accepted'
vgate_assert 03 serial-contains 'gotabwm: close'
vgate_assert 03 serial-contains 'gotabwm OK'
vgate_assert 03 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 03 serial-contains 'rx-gotabwm-launch-ok'
vgate_assert 03 serial-absent 'NOTEPAD.ELF'
vgate_assert 03 serial-absent 'CALC.BIN'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
manifest = open(os.path.join(share, "APPS.TXT"), errors="replace").read()
bins = []
for line in manifest.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or "|" not in s:
        continue
    bins.append(s.split("|", 1)[0].strip())
need = {"GOCALC.ELF", "NOTE.ELF", "GOEDIT.ELF", "GOFILES.ELF", "WEB.ELF"}
if not need.issubset(set(bins)):
    sys.exit("APPS.TXT missing daily set: %s" % sorted(need - set(bins)))
if "GOSH.ELF" not in bins and "GOTERM.ELF" not in bins:
    sys.exit("APPS.TXT missing GOSH.ELF and GOTERM.ELF")
for bad in ("NOTEPAD.ELF", "CALC.BIN", "CALC.ELF", "FILE.ELF", "DESKTOP.ELF"):
    if bad in bins:
        sys.exit("APPS.TXT still offers %s" % bad)
if "TABWM.BIN" in bins:
    # named fallback is allowed; dock=true is not
    for line in manifest.splitlines():
        if line.strip().startswith("TABWM.BIN") and "dock=true" in line:
            sys.exit("TABWM.BIN must not be a default dock target")
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first_after(prefix):
    for i, line in enumerate(ser):
        if line.startswith(prefix):
            return i
    sys.exit("missing %s" % prefix)
open_i = first_after("gotabwm: launcher open n=")
filt_i = first_after("gotabwm: launcher filter q=calc n=")
exec_i = first_after("gotabwm: launcher exec GOCALC.ELF")
if filt_i <= open_i:
    sys.exit("filter must follow open (open@%d filter@%d)" % (open_i, filt_i))
if exec_i <= filt_i:
    sys.exit("exec must follow filter (filter@%d exec@%d)" % (filt_i, exec_i))
print("launcher open@%d filter@%d exec@%d catalog honest" % (
    open_i, filt_i, exec_i))
PY
