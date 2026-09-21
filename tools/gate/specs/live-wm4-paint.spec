# live-wm4-paint.spec -- M32 WM4 (Lane 1, #707): WM rest policy blends unfocused, focused pure
#
# The two clients are Go apps now (NOTE.ELF since M66c, GOTOP.ELF since M71g
# #1566), and both paint their page with `theme.Current.Bg` — 0x182026, the
# value M69c pinned onto the Zig table. The background behind them is NOT a
# seat desktop: with a tab hosted the seat paints no desktop (seat.go keeps the
# blank desktop for the empty strip), so 0x101418 shows through — the kernel's
# own boot/text fill (kernel/src/text.zig bg_rgb).
#
# RE-PINNED BY MEASUREMENT in M71g. This spec's two focused-window
# expectations still read 0x101418 "NOTE.ELF's own palette" as M66c (#1445,
# d60c340a) pinned them — but M69c/c2 (a8b9aca7) moved NOTE off its local
# palette onto the token table, so the focused client has read 0x182026 ever
# since while nobody re-ran this spec. Both runs below failed on that stale
# byte when M71g touched them; the values now asserted are the ones the
# captures carry, plus a background control pixel that the old form lacked
# (0x182026 is also what the seat would paint for an empty strip, so "the rect
# is a window, not a blank desktop" needs the 0x101418 control to be an
# assertion at all).
#
# The MOVE side was unchanged and still holds: the kernel blits the unfocused
# window's OWN content at rest-alpha 240 (driving_award.zig client_alpha +
# blit_rect_alpha), so 0x182026 over 0x101418 lands on (23,31,37).
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wm4-paint "M32 WM4: WM rest policy blends unfocused, focused pure"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# M71g (#1566): the two openers are SPLIT so the window ids are deterministic.
# MEASURED on the retarget's first attempt (one burst, NOTE then GOTOP): the
# order `dui move 2` acts on follows whoever opens FIRST, and with both clients
# being Go runtimes that is a race — the old single burst only worked because
# TOP.BIN was Zig and always beat NOTE.ELF's Go runtime to win_open. Now GOTOP
# opens first (its own `top: ready` is the gate) and NOTE.ELF second, so window
# 2 is still GOTOP (moved, unfocused) and window 3 is still NOTE.ELF (newest,
# focused) — the roles the two pixel expectations below were measured in.
vgate_file script-A.txt <<'EOF'
wnd start
exec GOTOP.ELF
EOF

vgate_file s2-A.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file s3-A.txt <<'EOF'
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

vgate_run A -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-A' --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/s2-A.txt' --script2-after 'top: ready' --script2-delay 20 --script3 '$RUN_DIR/s3-A.txt' --script3-after 'note: ready' --script3-delay 20 --snapshot-after 'wm4-a-go' --script-expect 'wm4-a-go' --timeout 260

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
# Window 2 is GOTOP.ELF (see the script split above): it opens first, so
# `dui move 2` moves IT. Moved and UNFOCUSED, its own content (page fill
# 0x182026) is blitted over the background at rest-alpha 240 -> the blended
# value.
moved = [px(x, y) for y in range(290, 560, 5) for x in range(720, 1180, 5)]
(m_n, n_n) = mode(moved)
# The FOCUSED window is NOTE.ELF at 56,56 (opened last, so it holds focus):
# focused = PURE, so this is NOTE's own page fill itself — theme.Current.Bg,
# 0x182026. The two windows are pixel-identical in fill, so what this pair
# proves is the POLICY (one blended, one not), not which app is which; that
# identity comes from `dui move 2` and the serial chrome rows above.
note = [px(x, y) for y in range(90, 460, 5) for x in range(70, 540, 5)]
(m_c, n_c) = mode(note)
# Background control: a patch that is inside NEITHER window (window 1 ends at
# x=564, the moved window starts at x=704), so it must still be the kernel's
# 0x101418 — the assertion that the 0x182026 above is a WINDOW.
bg = [px(x, y) for y in range(590, 620) for x in range(600, 660)]
(m_b, n_b) = mode(bg)
print(f"moved_mode={m_n} note_focused_mode={m_c} note_frac={n_c / len(note):.2f} "
      f"background_mode={m_b}")
ok = (m_n == (23, 31, 37) and m_c == (24, 32, 38) and n_c / len(note) > 0.5
      and m_b == (16, 20, 24))
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
# Background control, same reason as run A: this boot's only window is NOTE at
# 56,56 512x384, so x=620..680 is outside it (and outside any dock).
bg = [px(x, y) for y in range(590, 620) for x in range(600, 660)]
(m_b, n_b) = mode(bg)
print(f"note_mode_focused={m_n} frac={n_n / len(note_area):.2f} background_mode={m_b}")
# Focused: the WM blits it with NO alpha, so this is NOTE.ELF's page fill
# itself (theme.Current.Bg = 0x182026 since M69c re-pinned the tables).
sys.exit(0 if (m_n == (24, 32, 38) and m_b == (16, 20, 24)
               and n_n / len(note_area) > 0.5) else 1)
PY
