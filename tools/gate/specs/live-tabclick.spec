# live-tabclick.spec -- M37 DQ3 tab mouse interaction (issue #839)

vgate_name live-tabclick "M37 DQ3 tab mouse interaction: click switches, × detaches, drag detaches"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_allow_rc A 0 1
vgate_allow_rc B 0 1
vgate_allow_rc C 0 1

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec TABHOLD.BIN
EOF

# --- boot A: click cell body → activate ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "440,82,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

# The click targets cell 1, which the strip always paints as the child
# (container first — see paint_tab_strip), so it must activate the ATTACHED
# window. Its id varies with open census (TABHOLD can be 2 or 3 — see
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
    --pointer-virtio "561,82,c" --pointer-virtio-after "tabhold: cycled" \
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
    --pointer-virtio "440,82,d;440,200,u" --pointer-virtio-after "tabhold: cycled" \
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
