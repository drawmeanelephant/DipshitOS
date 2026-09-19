# live-tabclick.spec -- M37 DQ3 tab mouse interaction (issue #839)
#
# M66c (#1485): the Zig notepad is retired; the tab HOST here is TOP.BIN, a
# Zig tab-aware app that still ships. The subject is the strip's HIT-TEST
# geometry and its cells, which is app-agnostic — but the coordinates are not:
# they are derived from the host's own rect. TOP declares 40,40 512x384
# (user/src/top.zig), so the strip is y 56..78 (host_y + title_bar_h 16) and
# its two cells are x 40..296 (container) / 296..552 (attached child), because
# paint_tab_strip lays the container's cell first. Same host and geometry as
# live-tabstrip.spec.

vgate_name live-tabclick "M37 DQ3 tab mouse interaction: click switches, × detaches, drag detaches"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_allow_rc A 0 1
vgate_allow_rc B 0 1
vgate_allow_rc C 0 1

vgate_file script-A.txt <<'EOF'
wnd start
exec TOP.BIN
exec TABHOLD.BIN
EOF

# --- boot A: click cell body → activate ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "424,67,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

# The click targets cell 1 (0-indexed), which the strip always paints as the
# child (container first — see paint_tab_strip), i.e. x 296..552 for the host
# above; its centre is 424. Its id varies with open census (TABHOLD can be 2 or 3 — see
# live-tabstrip.spec), so parse the child from THIS boot's attach line and
# require the click activated exactly that id.
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'(?m)^wnd: tab-attach child=(\d+) parent=(\d+)', ser)
if not m:
    print("tab-attach line missing", file=sys.stderr)
    sys.exit(1)
child, parent = m.group(1), m.group(2)
if child == parent:
    print(f"self-attach child==parent={child}", file=sys.stderr)
    sys.exit(1)
if not re.search(rf'(?m)^wnd: tab-activate id={child}$', ser):
    print(f"click did not activate the attached child id={child}", file=sys.stderr)
    sys.exit(1)
print(f"activate-ok child={child}")
PY
vgate_assert A python <<'PY'
import os
# Reset share state between boots
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot B: click × → detach, no drag ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "545,66,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

# Same census tolerance as boot A: the × click must detach the attached
# child (TABHOLD), whose id comes from this boot's attach line.
vgate_assert B python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'(?m)^wnd: tab-attach child=(\d+) parent=(\d+)', ser)
if not m:
    print("tab-attach line missing", file=sys.stderr)
    sys.exit(1)
child, parent = m.group(1), m.group(2)
if child == parent:
    print(f"self-attach child==parent={child}", file=sys.stderr)
    sys.exit(1)
if not re.search(rf'(?m)^wnd: tab-detach child={child}$', ser):
    print(f"× click did not detach child id={child}", file=sys.stderr)
    sys.exit(1)
print(f"detach-ok child={child}")
PY
vgate_assert B serial-absent "wnd: tab-drag"
vgate_assert B python <<'PY'
import os
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot C: drag out → detach at drop ---
vgate_run C -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "424,67,d;424,185,u" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

vgate_assert C serial-contains "wnd: tab-drag"
# Census-tolerant (see boot A): the drag-out must detach the attached
# child (TABHOLD), whose id comes from this boot's attach line.
vgate_assert C python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'(?m)^wnd: tab-attach child=(\d+) parent=(\d+)', ser)
if not m:
    print("tab-attach line missing", file=sys.stderr)
    sys.exit(1)
child, parent = m.group(1), m.group(2)
if child == parent:
    print(f"self-attach child==parent={child}", file=sys.stderr)
    sys.exit(1)
if not re.search(rf'(?m)^wnd: tab-detach child={child}$', ser):
    print(f"drag-out did not detach child id={child}", file=sys.stderr)
    sys.exit(1)
print(f"drag-detach-ok child={child}")
PY
