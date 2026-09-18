# live-tabwm-bt.spec -- M48 BT1-BT6 (umbrella #1120) class-B gate: the
# browser-style tab depth behaviours end to end on real VZ hardware.
#
# TWO headless boots sharing the seeded host share (`vgate_share seed`):
#
#   01  `tabwm start` + `exec NOTEPAD.BIN` + HID chords. Pins M48 markers and
#       the TWM quick-jump (`tabwm: go-summon` + `tabwm: go-scan-us=N`).
#       Ctrl+Shift+P / F persist pin+freeze into `.tabs` v2.
#   02  A second boot of TABWM + CALC against the same share. Proves the
#       v2 record's *content* (pin, freeze, title) actually restores —
#       boot 01 writing v2 without fault is not enough; the temp share used
#       to be discarded at run end.
#
# Chord sequence on 01 (after `notepad: open id=2`; via-virtio paces 0.25 s):
#   ctrl-shift-p, ctrl-shift-f, ctrl-shift-a, escape,
#   ctrl-shift-g, escape, ctrl-t, escape
#
# The class-A suite covers chords the runner cannot type. A v2 file is
# refused by a v1 parser (loud version mismatch → no saved state).

vgate_name live-tabwm-bt "M48 BT1-BT6: rail-native pin, freeze, start surface, tab search"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file script3.txt <<'EOF'
echo rx-m48-ok
EOF

vgate_file script-02.txt <<'EOF'
tabwm start
EOF

vgate_file script2-02.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file script3-02.txt <<'EOF'
echo rx-m48-v2-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-shift-p,ctrl-shift-f,ctrl-shift-a,escape,ctrl-shift-g,escape,ctrl-t,escape' \
    --input-chords-after 'notepad: open id=2' \
    --script3 '$RUN_DIR/script3.txt' --script3-after 'tabwm: start-surface' \
    --script-expect 'rx-m48-ok' --timeout 200

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'notepad: open id=2'
# M48 markers + the TWM Go quick-jump.
vgate_assert 01 serial-contains 'tabwm: tab-pin 2 on'
vgate_assert 01 serial-contains 'tabwm: tab-freeze 2 on'
vgate_assert 01 serial-contains 'tabwm: tab-search'
# TWM: the Go quick-jump (Ctrl+Shift+G) opens on real hardware.
vgate_assert 01 serial-contains 'tabwm: go-summon'
vgate_assert 01 serial-contains 'tabwm: go-scan-us='
vgate_assert 01 serial-contains 'tabwm: start-surface'
vgate_assert 01 serial-contains 'tabwm: new-tab'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
m = re.search(r"tabwm: go-scan-us=(\d+)", ser)
if not m:
    raise SystemExit("missing tabwm: go-scan-us")
us = int(m.group(1))
if us > 5000:
    raise SystemExit("go_refresh too slow: %d us (limit 5000)" % us)
share = os.environ["VG_SHARE"]
path = os.path.join(share, ".tabs")
data = open(path, "rb").read()
if not data or data[0] != 2:
    raise SystemExit(".tabs is not v2 (got %r)" % (data[:8],))
count = data[2]
if count < 1 or len(data) < 6 + count * 69:
    raise SystemExit("v2 truncated: len=%d count=%d" % (len(data), count))
found = None
for i in range(count):
    off = 6 + i * 69
    flags = data[off + 32]
    if (flags & 0x01) and (flags & 0x02):
        found = data[off:off + 69]
        break
if found is None:
    raise SystemExit("no v2 record with pin+freeze")
open(os.path.join(os.environ["RUN_DIR"], "tabs-v2-pinned.bin"), "wb").write(found)
PY

vgate_run 02 -- --screen '$RUN_DIR/screen' --via-virtio \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3-02.txt' --script3-after 'tabwm: tabs-applied' \
    --script-expect 'rx-m48-v2-ok' --timeout 120

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'tabwm: tabs-restored v2'
vgate_assert 02 serial-contains 'notepad: open id=2'
vgate_assert 02 serial-contains 'tabwm: tabs-applied v2'
vgate_assert 02 serial-contains 'pin=1'
vgate_assert 02 serial-contains 'freeze=1'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
m = re.search(r"tabwm: tabs-applied v2 n=(\d+) pin=(\d+) freeze=(\d+) title=(.*)", ser)
if not m:
    raise SystemExit("missing tabs-applied content line")
n, pin, freeze, title = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4).strip()
if n < 1 or pin < 1 or freeze < 1:
    raise SystemExit("restore missing pin/freeze: n=%d pin=%d freeze=%d" % (n, pin, freeze))
expect_path = os.path.join(os.environ["RUN_DIR"], "tabs-v2-pinned.bin")
expect = open(expect_path, "rb").read()
want_title = expect[:32].split(b"\x00", 1)[0].decode("ascii", "replace")
if title != want_title:
    raise SystemExit("restored title %r != boot1 title %r" % (title, want_title))
share = os.environ["VG_SHARE"]
data = open(os.path.join(share, ".tabs"), "rb").read()
if not data or data[0] != 2:
    raise SystemExit("boot2 .tabs is not v2")
got = None
for i in range(data[2]):
    off = 6 + i * 69
    rec = data[off:off + 69]
    if rec[:32] == expect[:32] and (rec[32] & 0x03) == 0x03:
        got = rec
        break
if got is None:
    raise SystemExit("boot2 .tabs lost pin+freeze for %r" % (want_title,))
PY
