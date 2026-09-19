# live-wm4-paint.spec -- M32 WM4 (Lane 1, #707): WM rest policy blends unfocused, focused pure
#
# M66c (#1485): the Zig notepad is retired; the moved/unfocused client is
# NOTE.ELF (Go), whose page fill is 0x101418 (its own palette, not the Zig
# theme's 0x182026). The rect it declares is the same 56,56 512x384, so only
# the two app-painted colour expectations below moved. TOP.BIN, the focused
# window in boot A, is still the Zig app and its 0x182026 is unchanged.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wm4-paint "M32 WM4: WM rest policy blends unfocused, focused pure"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTE.ELF
exec TOP.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui move 2 700 200
dui
wm
echo wm4-a-go
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo wm4-b-go
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run A -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-A' --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/s2-A.txt' --script2-after 'top: ready' --script2-delay 20 --snapshot-after 'wm4-a-go' --script-expect 'wm4-a-go' --timeout 260

vgate_assert A serial-contains 'wnd: rest-alpha=240'
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wm: chrome window id=2 kind=0x[0-9a-f]+ rest=240', ser), "rest alpha id=2 check failed"
assert re.search(r'wm: chrome window id=3 kind=0x[0-9a-f]+ rest=240', ser), "rest alpha id=3 check failed"
PY
vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys, collections
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def mode(grid):
    return collections.Counter(grid).most_common(1)[0]
# Window 2 is TOP.BIN, not the Go client: NOTE.ELF's window lands second
# (its Go runtime start is slower than the Zig apps' open), so `dui move 2`
# moves TOP. Moved and UNFOCUSED, TOP keeps the Zig theme's client
# (0x182026 = 24,32,38) at rest-alpha 240, so the mode is the blended value.
moved = [px(x, y) for y in range(290, 560, 5) for x in range(720, 1180, 5)]
(m_n, n_n) = mode(moved)
# The FOCUSED window is NOTE.ELF at 56,56 (opened last, so it holds focus):
# focused = pure, and its own page fill is 0x101418.
note = [px(x, y) for y in range(90, 460, 5) for x in range(70, 540, 5)]
(m_c, n_c) = mode(note)
print(f"moved_mode={m_n} note_focused_mode={m_c} note_frac={n_c / len(note):.2f}")
ok = m_n == (23, 31, 37) and m_c == (16, 20, 24) and n_c / len(note) > 0.5
sys.exit(0 if ok else 1)
PY

vgate_run B -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-B' --script '$RUN_DIR/script-B.txt' --script2 '$RUN_DIR/s2-B.txt' --script2-after 'note: ready' --script2-delay 20 --snapshot-after 'wm4-b-go' --script-expect 'wm4-b-go' --timeout 260

vgate_assert B snapshot 'snap-B-*.raw' <<'PY'
import sys, collections
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def mode(grid):
    return collections.Counter(grid).most_common(1)[0]
note_area = [px(x, y) for y in range(140, 410, 5) for x in range(84, 560, 5)]
(m_n, n_n) = mode(note_area)
print(f"note_mode_focused={m_n} frac={n_n / len(note_area):.2f}")
# Focused: the WM paints it pure, so this is NOTE.ELF's page fill itself.
sys.exit(0 if m_n == (16, 20, 24) and n_n / len(note_area) > 0.5 else 1)
PY
