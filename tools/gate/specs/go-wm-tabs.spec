# go-wm-tabs.spec -- M62b (issue #1400) + M62c (issue #1401) class-B gate:
# GOTABWM tab strip, then a constrained two-pane split. Two tabapp clients
# (leftover Zig CALC + NOTEPAD) declare over WM_RPC; the rail paints with
# n=2; SplitV then Unsplit then SplitH then Unsplit; applied pane rects
# match the LAYOUT.txt-shaped dump; unsplit restores full-viewport; then
# close focused / last, empty desktop, seat still registered until exit.
#
# Seed wm=none and exec GOTABWM.ELF like go-wm-seat: this is the Go seat,
# not Zig TABWM. Do not overload go-wm-seat or go-wm-default. Kernel
# untouched. No HID. No framebuffer golden. No LAYOUT.txt file (M62f).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-tabs-ok`, which
# only the script prints, and every stage gate waits on guest output
# (`gotabwm: win focus`, `wm: unregistered, shim resumed`). Two execs in
# script2 start in parallel after the window phase is waiting for blur;
# both declares sit in the mailbox until the serve loop drains them.

vgate_name go-wm-tabs "issues #1400/#1401 M62b+c: GOTABWM tab strip + constrained two-pane split on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
exec CALC.BIN
exec NOTEPAD.BIN
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-tabs-ok
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
# Explicit opt-in, same as go-wm-seat: the compiled default is already the
# Go seat (M59). Seed wm=none so this boot proves the tab strip on an
# executed GOTABWM, not the autostart path.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-tabs-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'exec: loaded CALC.BIN'
vgate_assert 01 serial-contains 'exec: loaded NOTEPAD.BIN'
# Two clients on the strip, rail painted, one focused.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 2
vgate_assert 01 serial-contains 'gotabwm: tab focus id='
vgate_assert 01 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 01 serial-contains 'calc: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'notepad: tab-aware (full-viewport)'
# M62c: integer two-pane split. Dump lines (LAYOUT.txt shape) plus the
# applied pane (SET_WINDOW accepted; slot 19 WinQuery is owner-only so
# the seat cannot read a hosted client's rect). Unsplit restores 1280x720.
# Remainder-free on this scanout. Clients print resize relayout = WIN_RESIZE.
vgate_assert 01 serial-contains 'gotabwm: split v'
vgate_assert 01 serial-contains 'split=v'
vgate_assert 01 serial-contains 'x=640 y=0 w=640 h=720'
vgate_assert 01 serial-contains 'gotabwm: split h'
vgate_assert 01 serial-contains 'split=h'
vgate_assert 01 serial-contains 'y=360 w=1280 h=360'
vgate_assert 01 serial-count 'gotabwm: unsplit' 2
vgate_assert 01 serial-contains 'split=none'
vgate_assert 01 serial-contains 'x=0 y=0 w=1280 h=720'
vgate_assert 01 serial-contains 'calc: resize relayout'
vgate_assert 01 serial-contains 'notepad: resize relayout'
# Pair each layout dump with the applied pane line dumpTab prints next.
# Every pair must match within 1 px (integer-half remainder).
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lay_re = re.compile(
    r"^gotabwm: layout tab=(\d+) bin=\S+ x=(\d+) y=(\d+) w=(\d+) h=(\d+) ")
pane_re = re.compile(
    r"^gotabwm: pane id=(\d+) x=(\d+) y=(\d+) w=(\d+) h=(\d+)$")
n = 0
pending = None
for line in ser.splitlines():
    lm = lay_re.match(line)
    if lm:
        pending = lm
        continue
    pm = pane_re.match(line)
    if not pm:
        continue
    if pending is None:
        sys.exit("pane line with no preceding layout dump: " + line)
    if pending.group(1) != pm.group(1):
        sys.exit("layout tab=%s paired with pane id=%s" % (
            pending.group(1), pm.group(1)))
    for i, name in ((2, "x"), (3, "y"), (4, "w"), (5, "h")):
        a, b = int(pending.group(i)), int(pm.group(i))
        if abs(a - b) > 1:
            sys.exit("tab %s %s dump=%d applied=%d (tol 1)" % (
                pending.group(1), name, a, b))
    n += 1
    pending = None
if n < 8:
    sys.exit("only %d layout/pane pairs (want >= 8: V+unsplit+H+unsplit x2)" % n)
print("layout vs applied pane: %d pairs within 1 px" % n)
PY
# Close focused -> remaining focused -> last close leaves the strip empty
# while the seat is still in its composite loop (tabs empty before close).
vgate_assert 01 serial-count 'gotabwm: tab close id=' 2
vgate_assert 01 serial-contains 'gotabwm: rail n=1 focus='
vgate_assert 01 serial-contains 'gotabwm: tabs empty'
vgate_assert 01 serial-contains 'calc: win_close'
vgate_assert 01 serial-contains 'notepad: win_close'
vgate_assert 01 serial-contains 'gotabwm: host done'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-tabs-ok'
# M52: no zombie window, registry back to the four fixed layers.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
