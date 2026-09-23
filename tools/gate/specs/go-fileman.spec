# go-fileman.spec -- M74a (issue #1644): GOFILES.ELF is a Bubble Tea TUI over
# the bound /dev/tty: one chord batch navigates into a seeded dir, comes back,
# selects KNOWN.TXT (preview pane), renames it, and the re-list shows the
# change. The screenshot asserts the preview pane's exact truecolour accent
# (M73h) in the real scanout — not a host ANSI render.
#
# Shape: go-charmhello — direct exec on the kernel desktop (no `tabwm start`
# seat), native 512x384 window = the kernel grid's 64x46 client (cols <= the
# grid's 80-col cap), chords over the real HID path, `dui` rect proof, and a
# screenshot barrier on the app's own post-rename marker. This spec RETIRES
# go-files.spec (M58a): one file manager, one spec.
#
# Marker discipline is load-bearing: the app flushes each frame's markers
# only AFTER painting it, so the screenshot at `gofiles: renamed …` sees the
# renamed frame, and `gofiles: settled after rename` (one yield later) is
# what script3 waits on before closing — the teardown can never race the
# capture.
#
# exec-order: assert-proven -- the run ends on `rx-go-fileman-ok`, which only
# script3 prints, and script3 waits on the app's own settle marker; an app
# that never ran, never renamed, or never settled cannot pass.

vgate_name go-fileman "M74a #1644: the GOFILES.ELF Charm file manager navigates, previews (pixel-asserted) and renames over the bound tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOFILES.ELF /host/FM
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
echo rx-go-fileman-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
fm = os.path.join(share, "FM")
os.makedirs(fm, exist_ok=True)
known = os.path.join(fm, "KNOWN.TXT")
with open(known, "w") as f:
    f.write("hello-from-gofiles\npreview-line-alpha\npreview-line-beta\n")
sub = os.path.join(fm, "SUB")
os.makedirs(sub, exist_ok=True)
inner = os.path.join(sub, "INNER.TXT")
with open(inner, "w") as f:
    f.write("inner-file-preview\n")
print("staged GOFILES.ELF into share (%d bytes), %s (%d bytes), %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOFILES.ELF")),
       known, os.path.getsize(known), inner, os.path.getsize(inner)))
PY

# The chord batch, in full (17 strokes at the cv-input transport's fixed
# 0.25 s): enter the sorted-first dir SUB, come back up, move onto
# KNOWN.TXT (dirs sort first), open the EMPTY rename prompt, type the new
# name one rune at a time, commit. Lowercase avoids any shift ambiguity in
# the HID chord table.
vgate_run 01 -- \
    --screen '$RUN_DIR/fileman-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'return,backspace,down,r,n,e,w,n,a,m,e,.,t,x,t,return' \
    --input-chords-after 'gofiles: ready' \
    --screenshot-after 'gofiles: renamed KNOWN.TXT -> newname.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gofiles: renamed KNOWN.TXT -> newname.txt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gofiles: settled after rename' \
    --script-expect 'rx-go-fileman-ok' --timeout 240

# --- serial: the app ran, navigated, previewed, acted -----------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 01 serial-contains 'gofiles: open id='
# The fullscreen declare is best-effort (tabapp doc): on the kernel
# desktop no TABWM exists to accept it, and the shim refuses honestly —
# the app keeps its native presentation.
vgate_assert 01 serial-contains 'gofiles: declare refused'
vgate_assert 01 serial-contains 'gofiles: attached'
vgate_assert 01 serial-contains 'gofiles: painted'
vgate_assert 01 serial-contains 'gofiles: ready'
vgate_assert 01 serial-contains 'gofiles: present'

# The window itself: native rect on the kernel desktop (dui from script2,
# fired at the rename barrier, so it describes the live window) — the
# charmhello dui row shape, plus the kernel's own blit counters showing the
# tty band was composited.
vgate_assert 01 serial-contains 'dui[4]: user user rect=32,32,512,384'

# First listing of the seeded dir: dirs-first order (SUB before KNOWN.TXT)
# and the M58a found-marker.
vgate_assert 01 serial-contains 'gofiles: list /host/FM n=2'
vgate_assert 01 serial-contains 'gofiles: entry SUB dir'
vgate_assert 01 serial-contains 'gofiles: entry KNOWN.TXT file'
vgate_assert 01 serial-contains 'gofiles: found KNOWN.TXT'

# Navigate: enter SUB (preview INNER.TXT), come back, select KNOWN.TXT.
vgate_assert 01 serial-contains 'gofiles: cd /host/FM/SUB'
vgate_assert 01 serial-contains 'gofiles: view INNER.TXT bytes='
vgate_assert 01 serial-contains 'gofiles: key return'
vgate_assert 01 serial-contains 'gofiles: key backspace'
vgate_assert 01 serial-contains 'gofiles: key down'
vgate_assert 01 serial-contains 'gofiles: view KNOWN.TXT bytes='

# Act: rename commits (the syscall returned) and the re-list shows the new
# name; the preview follows the renamed entry.
vgate_assert 01 serial-contains 'gofiles: renamed KNOWN.TXT -> newname.txt'
vgate_assert 01 serial-contains 'gofiles: list /host/FM n=2'
vgate_assert 01 serial-contains 'gofiles: entry newname.txt file'
vgate_assert 01 serial-contains 'gofiles: view newname.txt bytes='
vgate_assert 01 serial-contains 'gofiles: settled after rename'

# Clean teardown through the window-close path.
vgate_assert 01 serial-contains 'gofiles: close'
vgate_assert 01 serial-contains 'gofiles OK'
vgate_assert 01 serial-contains 'rx-go-fileman-ok'

# --- serial: the refusals that must NOT happen ------------------------------
vgate_assert 01 serial-absent 'gofiles: rename refused'
vgate_assert 01 serial-absent 'gofiles: list error'
vgate_assert 01 serial-absent 'gofiles: no /dev/tty'
vgate_assert 01 serial-absent 'gofiles: attach failed'
# M73i selection precedence: with ?1000/?1006 enabled, a plain pointer
# never falls through to kernel selection.
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- scanout: the preview pane's exact accent in the REAL framebuffer -------
# The barrier is the rename marker itself (printed AFTER its frame painted).
# At that frame the selection sits on newname.txt and its preview text —
# painted by the kernel's truecolour path at exactly (122,162,255) — is in
# the right pane; the selected-row background is (44,58,76). Tolerances
# absorb the capture path's edge interpolation; the counts are far above
# what any other window element can contribute.
vgate_assert 01 snapshot 'fileman-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            pred = (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)
            row[x] = (row[x] + pred) & 0xff
    out += row
    prev = row

# The window occupies the native 512x384 client at (32, 48): the preview
# pane lives right of the list split (col 28+) and below the pane headers
# (row 2+), so the accent is only ever painted inside that rect — and the
# selected row's background band is a solid slab of (44,58,76).
accent = selbg = 0
for y in range(48, 48 + 368):
    for x in range(32, 32 + 512):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if abs(r - 122) <= 8 and abs(g - 162) <= 8 and abs(b - 255) <= 8:
            accent += 1
        if abs(r - 44) <= 6 and abs(g - 58) <= 6 and abs(b - 76) <= 6:
            selbg += 1
print("fileman scanout: preview-accent=%d sel-bg=%d" % (accent, selbg))
assert accent >= 40, "preview pane accent (122,162,255) absent from the client rect"
assert selbg >= 100, "selected-row background (44,58,76) absent from the client rect"
PY
