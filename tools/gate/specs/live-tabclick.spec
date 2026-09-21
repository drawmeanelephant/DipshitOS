# live-tabclick.spec -- M37 DQ3 tab mouse interaction (issue #839)
#
# M71g (#1566): the tab HOST here is GOTOP.ELF, the Go successor to Zig
# TOP.BIN (user/go/top). It declares the SAME 40,40 512x384 rect TOP declared,
# so every coordinate below is unchanged. The subject is the strip's HIT-TEST
# geometry and its cells, which is app-agnostic — but the coordinates are not:
# they are derived from the host's own rect. GOTOP declares 40,40 512x384
# (user/go/top/main.go), so the strip is y 56..78 (host_y + title_bar_h 16) and
# its two cells are x 40..296 (container) / 296..552 (attached child), because
# paint_tab_strip lays the container's cell first. Same host and geometry as
# live-tabstrip.spec.

vgate_name live-tabclick "M37 DQ3 tab mouse interaction: click switches, × detaches, drag detaches"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_allow_rc A 0 1
vgate_allow_rc B 0 1
vgate_allow_rc C 0 1

# M71g (#1566): the tab HOST is DEVCONS.BIN, a Zig app, and the two openers go
# back into ONE burst. This spec's subject is the strip's mouse GEOMETRY, and
# GOTOP.ELF cannot host it (MEASURED, not assumed — two boots, both shapes):
#   * one burst: TABHOLD (Zig) reserved the attach against a container whose
#     Go runtime had not painted yet (`wnd: tab-attach child=2 parent=3` before
#     `open: id=3 owner=2`); the container then composited nothing anywhere in
#     the frame.
#   * split (attach after `top: ready`): the strip PAINTED correctly — divider
#     at x=296, band 40..552, y 56..78, verified by decoding the snapshot — yet
#     NEITHER cell click produced a `wnd: tab-activate` line, while the same
#     clicks against a Zig host activate/detach/drag (ds-fb-m70 run A:
#     `tab-activate id=3` after `tabhold: cycled`).
# The cause is not diagnosed here and is filed as its own card (a late attach
# leaves the strip unclickable, which is user-visible for any slow-opening
# container). Until it is fixed, this spec keeps a Zig host that OPENS BEFORE
# the attach, which is the shape its coordinates were measured in.
#
# DEVCONS declares 260,24 400x300 (user/src/devcons.zig), so with
# title_bar_h 16 the strip is y 40..62 and its two cells are x 260..460
# (container) / 460..660 (attached child, laid down second).
vgate_file script-A.txt <<'EOF'
wnd start
exec DEVCONS.BIN
exec TABHOLD.BIN
EOF

# --- boot A: click cell body → activate ---
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
PY

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "560,51,c" --pointer-virtio-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

# The click targets cell 1 (0-indexed), which the strip always paints as the
# child (container first — see paint_tab_strip), i.e. x 460..660 for the host
# above; its centre is 560. Its id varies with open census (TABHOLD can be 2 or 3 — see
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
    --pointer-virtio "653,50,c" --pointer-virtio-after "tabhold: cycled" \
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
    --pointer-virtio "560,51,d;560,169,u" --pointer-virtio-after "tabhold: cycled" \
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
