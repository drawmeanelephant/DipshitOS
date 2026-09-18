# go-wm-tabs.spec -- M62b–h + #1426 (issues #1400–#1406/#1426)
# class-B gate: GOTABWM tab strip, split, pin, session, LAYOUT.txt, then two
# shipping Go ELFs as tabs. Boot 01 hosts GOCALC.ELF + leftover NOTEPAD.BIN
# (Zig CALC.BIN is gone, M62h / #1406). Boot 03 hosts GOEDIT.ELF + GOTERM.ELF:
# both declared, focus switch, both alive, close one without killing the
# seat, LAYOUT.txt names both bins. scheduler.max_tasks=13 (#1426) so three
# Go runtimes fit (GOTABWM+GOEDIT+GOTERM = 12 occupied + one spare; idle
# stays max_tasks-1).
#
# THREE vgate_runs share one seeded host share (`vgate_share seed`):
#   01  GOCALC+NOTEPAD; pin-stay writes SESSION.TABS; last unsplit writes
#       LAYOUT.txt (closed before the serial line that names it).
#   02  GOTABWM only. Restores the session; then drops SESSION.TABS.
#   03  GOEDIT+GOTERM, empty strip. Same two-tab choreography.
#
# Seed wm=none and exec GOTABWM.ELF like go-wm-seat. No HID. No framebuffer
# golden. Do not overload go-wm-seat or go-wm-default.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#   bash tools/go/build-goterm.sh    ->  .build/go/GOTERM.ELF
#
# exec-order: assert-proven -- each run ends on a marker only its script
# prints (`rx-gotabwm-tabs-ok` / `rx-gotabwm-session-ok` / `rx-gotabwm-apps-ok`).
# Stage gates wait on guest output (`gotabwm: win focus`,
# `wm: unregistered, shim resumed`). Boot 03 uses GOMAXPROCS=1 so each Go
# runtime stays at 3 kernel tasks (primary + sysmon + helper).

vgate_name go-wm-tabs "issues #1400–#1405/#1426: GOTABWM tabs + session + LAYOUT.txt + two Go ELFs on VZ"
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
exec NOTEPAD.BIN
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-tabs-ok
EOF

vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-02.txt <<'EOF'
wm
echo rx-gotabwm-session-ok
EOF

# Boot 03: two shipping Go ELFs (GOEDIT + GOTERM). max_tasks=13 fits three
# Go runtimes (seat + two clients). GOMAXPROCS=1 is the exec envp knob (#1226).
vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
exec GOTERM.ELF
EOF

vgate_file script3-03.txt <<'EOF'
wm
dui
echo rx-gotabwm-apps-ok
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
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
print("seeded %s (%d bytes)" % (seed, os.path.getsize(seed)))
# Explicit opt-in, same as go-wm-seat: the compiled default is already the
# Go seat (M59). Seed wm=none so this boot proves the tab strip on an
# executed GOTABWM, not the autostart path.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
# Seed is a fresh RUN_DIR/share per gate, but a leftover SESSION.TABS on a
# reused share would make boot 01 loadSession set stripDone and skip the
# M62b–d choreography. Drop it so boot 01 starts empty.
stale = os.path.join(share, "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared stale SESSION.TABS")
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
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'exec: loaded NOTEPAD.BIN'
# Two clients on the strip, rail painted, one focused.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 2
vgate_assert 01 serial-contains 'gotabwm: tab focus id='
vgate_assert 01 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'notepad: tab-aware (full-viewport)'
# M62d: reorder two unpinned tabs; pin jumps to the left and stays there
# across a focus change. Order line names ids + pin bits (not LAYOUT.txt).
# There is no kernel pin object: the first dump is Pin() on the strip; the
# second is only printed after WmctlTaskbarClick actually took focus.
vgate_assert 01 serial-contains 'gotabwm: reorder 0->1'
vgate_assert 01 serial-contains 'gotabwm: pin id='
vgate_assert 01 serial-contains 'gotabwm: order ids='
vgate_assert 01 serial-contains 'pin=1,0'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
pinned = []
for line in ser.splitlines():
    m = order_re.match(line)
    if not m:
        continue
    if m.group(3) == "1" and m.group(4) == "0":
        pinned.append((m.group(1), m.group(2), m.group(5)))
if len(pinned) < 2:
    sys.exit("want >=2 order lines with pin=1,0 (pin then focus), got %d" %
             len(pinned))
if pinned[0][0] != pinned[1][0] or pinned[0][1] != pinned[1][1]:
    sys.exit("pin did not stay left across focus: %s then %s" % (
        pinned[0], pinned[1]))
if pinned[0][2] == pinned[1][2]:
    sys.exit("focus did not change between pin-left dumps: focus=%s" %
             pinned[0][2])
print("pin stayed left ids=%s,%s across focus %s -> %s" % (
    pinned[0][0], pinned[0][1], pinned[0][2], pinned[1][2]))
PY
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
vgate_assert 01 serial-contains 'gocalc: present'
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
vgate_assert 01 serial-contains 'gocalc: close'
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
# M62e: pin-stay wrote `.tabs` v2 while both tabs still existed. Closes
# after that must not overwrite the file with an empty strip.
vgate_assert 01 serial-contains 'gotabwm: session write n=2'
vgate_assert 01 python <<'PY'
import os, sys
# Offsets match user/go/gotabwm/tabsv2.go: tabsV2HeaderBytes=6,
# tabsV2RecordBytes=69, tabsV2TitleMax=32. Record 0 title at 6, flags at
# 38; record 1 starts at 75, flags at 107.
p = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69 * 2:
    sys.exit("SESSION.TABS too short: %d bytes" % len(b))
if b[0] != 2:
    sys.exit("version byte %d want 2" % b[0])
if b[2] != 2:
    sys.exit("count %d want 2" % b[2])
if b[1] != 1:
    sys.exit("active+1 = %d want 1 (Calc, index 0)" % b[1])
title0 = b[6:38].split(b"\x00", 1)[0]
title1 = b[75:107].split(b"\x00", 1)[0]
if title0 != b"Calc" or title1 != b"Notepad":
    sys.exit("titles %r %r want Calc, Notepad" % (title0, title1))
if b[38] != 1:
    sys.exit("record 0 flags %#x want pinned" % b[38])
if b[107] != 0:
    sys.exit("record 1 flags %#x want unpinned" % b[107])
print("SESSION.TABS v2 n=2 Calc pinned left, Calc active")
PY
# M62f: LAYOUT.txt is closed before the serial line that names it. Last
# two-tab write is the unsplit full-viewport dump (closes do not rewrite).
vgate_assert 01 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
vgate_assert 01 share-contains SELFTEST/LAYOUT.txt 'split=none'
vgate_assert 01 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
try:
    raw = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SELFTEST/LAYOUT.txt missing on the share")
if b"\r" in raw:
    sys.exit("LAYOUT.txt contains CR")
if not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt is not LF-terminated")
text = raw.decode("utf-8")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = text.splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = []
for line in lines:
    m = line_re.match(line)
    if not m:
        sys.exit("bad LAYOUT line: %r" % line)
    parsed.append(m.groups())
ids = {parsed[0][0], parsed[1][0]}
if len(ids) != 2:
    sys.exit("tab ids not unique: %s" % (ids,))
bins = {parsed[0][1], parsed[1][1]}
if bins != {"GOCALC.ELF", "NOTEPAD.BIN"}:
    sys.exit("bins %s want GOCALC.ELF and NOTEPAD.BIN" % (bins,))
for row in parsed:
    if row[2:6] != ("0", "0", "1280", "720") or row[7] != "none":
        sys.exit("last dump must be unsplit full-viewport, got %s" % (row,))
foci = {parsed[0][6], parsed[1][6]}
if foci != {"0", "1"}:
    sys.exit("need one focused tab, focus bits %s" % (foci,))
print("LAYOUT.txt n=2 unsplit 1280x720 bins=%s focus ok" % ",".join(sorted(bins)))
PY

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-session-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: session load n=2'
vgate_assert 02 serial-contains 'gotabwm: session titles=Calc,Notepad pin=1,0 active=0'
vgate_assert 02 serial-contains 'gotabwm: order ids='
vgate_assert 02 serial-contains 'pin=1,0'
vgate_assert 02 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 02 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
# Restored placeholder ids are not kernel windows: skip split/close.
vgate_assert 02 serial-absent 'gotabwm: split '
vgate_assert 02 serial-absent 'gotabwm: tab close id='
vgate_assert 02 serial-absent 'gotabwm: session bad'
vgate_assert 02 share-contains SELFTEST/LAYOUT.txt 'bin=GOCALC.ELF'
vgate_assert 02 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
raw = open(p, "rb").read()
if b"\r" in raw or not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt encoding")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = [line_re.match(line) for line in lines]
if not all(parsed):
    sys.exit("bad LAYOUT line in %r" % lines)
ids = [parsed[0].group(1), parsed[1].group(1)]
if ids != ["256", "257"]:
    sys.exit("restored ids %s want 256,257 (sessionIDBase=0x100)" % ids)
bins = [parsed[0].group(2), parsed[1].group(2)]
if bins != ["GOCALC.ELF", "NOTEPAD.BIN"]:
    sys.exit("bins %s" % bins)
if parsed[0].group(8) != "none" or parsed[1].group(8) != "none":
    sys.exit("restore dump must be unsplit")
print("LAYOUT.txt restore n=2 ids=256,257 unsplit")
# Boot 03 must not restore Calc/Notepad session placeholders.
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    os.remove(stale)
except FileNotFoundError:
    sys.exit("SESSION.TABS missing after restore (boot 02)")
print("cleared SESSION.TABS for boot 03")
PY
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'gotabwm: close'
vgate_assert 02 serial-contains 'gotabwm OK'
vgate_assert 02 serial-contains 'rx-gotabwm-session-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-apps-ok' --timeout 300

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 03 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 03 serial-contains 'goedit: open id='
vgate_assert 03 serial-contains 'goedit: declare accepted'
vgate_assert 03 serial-contains 'goedit: present'
vgate_assert 03 serial-contains 'goedit: read /host/EDIT/SEED.TXT n=10'
vgate_assert 03 serial-contains 'goterm: open id='
vgate_assert 03 serial-contains 'goterm: declare accepted'
vgate_assert 03 serial-contains 'goterm: attached'
vgate_assert 03 serial-count 'gotabwm: tab open id=' 2
vgate_assert 03 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 03 serial-contains 'gotabwm: tab focus id='
vgate_assert 03 serial-absent 'gotabwm: session load n='
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
edit = ser.find("goedit: present")
term = ser.find("goterm: attached")
close = ser.find("gotabwm: tab close id=")
if edit < 0 or term < 0:
    sys.exit("missing app syscall markers")
if close < 0:
    sys.exit("no tab close")
if not (edit < close and term < close):
    sys.exit("an app was closed before both were alive (edit=%d term=%d close=%d)" %
             (edit, term, close))
print("GOEDIT present and GOTERM attached before first tab close")
PY
vgate_assert 03 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
vgate_assert 03 share-contains SELFTEST/LAYOUT.txt 'bin=GOEDIT.ELF'
vgate_assert 03 share-contains SELFTEST/LAYOUT.txt 'bin=GOTERM.ELF'
vgate_assert 03 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
raw = open(p, "rb").read()
if b"\r" in raw or not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt encoding")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = []
for line in lines:
    m = line_re.match(line)
    if not m:
        sys.exit("bad LAYOUT line: %r" % line)
    parsed.append(m.groups())
bins = {parsed[0][1], parsed[1][1]}
if bins != {"GOEDIT.ELF", "GOTERM.ELF"}:
    sys.exit("bins %s want GOEDIT.ELF and GOTERM.ELF" % (bins,))
for row in parsed:
    if row[2:6] != ("0", "0", "1280", "720") or row[7] != "none":
        sys.exit("last dump must be unsplit full-viewport, got %s" % (row,))
foci = {parsed[0][6], parsed[1][6]}
if foci != {"0", "1"}:
    sys.exit("need one focused tab, focus bits %s" % (foci,))
print("LAYOUT.txt n=2 unsplit 1280x720 bins=GOEDIT.ELF,GOTERM.ELF")
PY
vgate_assert 03 serial-count 'gotabwm: tab close id=' 2
vgate_assert 03 serial-contains 'gotabwm: rail n=1 focus='
vgate_assert 03 serial-contains 'gotabwm: tabs empty'
vgate_assert 03 serial-contains 'goedit: close'
vgate_assert 03 serial-contains 'goterm: close'
vgate_assert 03 serial-contains 'gotabwm: host done'
vgate_assert 03 serial-contains 'gotabwm: close'
vgate_assert 03 serial-contains 'gotabwm OK'
vgate_assert 03 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 03 serial-contains 'rx-gotabwm-apps-ok'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'newosproc: sys_thread create failed'
