# go-gitui.spec -- M74b #1645: GOGITUI.ELF opens a REAL repository at
# /host/R and renders status, log and diff views into its window over the
# bound /dev/tty (tea.Model, M72c loop shape). The seed is host `git`
# (go-git.spec precedent): two commits with pinned dates, one staged add,
# one unstaged edit, one untracked file — all LOOSE objects, deliberately
# not repacked: a pack filename is 50 bytes against vi.DirEntry.Name[32]
# and a pack path needs 76 bytes against file_table.max_path_len (64), so
# the guest can neither enumerate nor open packs (deliverable 4 #1645
# records both measured bounds and the kernel-side change they imply).
# Loose object paths are 62 bytes here — exactly the fit store.go's
# maxPath was designed for — and a GOTGIT clone writes loose objects too,
# so this is the shape a clone integration will actually read; the pack
# path is covered host-side (gitread tests parse real packs, deltas
# included). The index the reader parses is real `git add` output,
# closing the layout loop host tests can only approximate.
#
# Views are proven by serial data markers (entries, subjects, diff paths)
# AND by PNG colour counts with exclusivity zeros: each view paints only
# its own colour class (status green/yellow/red, log cyan shas, diff
# green/red/blue hunks; the magenta header is the app identity), so a
# screenshot that showed the wrong view fails on BOTH counts.
#
# Mouse: M73i ?1000/?1006 enabled by the app; run 01 clicks the `log` tab
# (cell x=12 y=1 = screen 124,52 over the 32,32 rect with 16 px title) and
# must switch views — press b=0 and release b=32 are both reported, never
# consumed by kernel selection (`term sel` must stay absent).
#
# exec-order: assert-proven -- input waits for ready, the screenshot waits
# for the view marker (emitted AFTER the frame write + yield), dui waits on
# its own marker, the close waits for `dui: windows=`.
#
# HOST PREREQUISITE (fails honestly when missing):
#   bash tools/go/build-gitui.sh -> .build/go/GOGITUI.ELF plus `git` on
#   PATH for the seed.

vgate_name go-gitui "M74b: in-guest Git TUI over local .git — status/log/diff over a real dirty repo, HID keys and an M73i tab click"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOGITUI.ELF /host/R
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
EOF

vgate_file scriptL.txt <<'EOF'
exec GOGITUI.ELF /host/R
EOF

vgate_file scriptL2.txt <<'EOF'
dui
EOF

vgate_file scriptL3.txt <<'EOF'
dui close 2
EOF

vgate_file scriptD.txt <<'EOF'
exec GOGITUI.ELF /host/R
EOF

vgate_file scriptD2.txt <<'EOF'
dui
EOF

vgate_file scriptD3.txt <<'EOF'
dui close 2
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

elf = os.path.join(".build", "go", "GOGITUI.ELF")
if not os.path.exists(elf):
    sys.exit("GOGITUI.ELF missing (expected " + elf + ") - build it first: "
             "bash tools/go/build-gitui.sh")
shutil.copy(elf, os.path.join(share, "GOGITUI.ELF"))

git = shutil.which("git")
if not git:
    sys.exit("git not on PATH; go-gitui seeds a real repository")

work = os.path.join(run, "seedwork")
shutil.rmtree(work, ignore_errors=True)
os.makedirs(work)
env = os.environ.copy()
env.update({
    "GIT_AUTHOR_NAME": "g", "GIT_AUTHOR_EMAIL": "g@g",
    "GIT_AUTHOR_DATE": "1000000000 +0000",
    "GIT_COMMITTER_NAME": "g", "GIT_COMMITTER_EMAIL": "g@g",
    "GIT_COMMITTER_DATE": "1000000000 +0000",
})

def g(*args):
    subprocess.check_call([git, "-c", "init.defaultBranch=main"] + list(args),
                          cwd=work, env=env)

# commit one: hello.txt + notes.txt
g("init", "-q")
open(os.path.join(work, "hello.txt"), "w").write("alpha\ndelta\ngamma\n")
open(os.path.join(work, "notes.txt"), "w").write("one\ntwo\n")
g("add", "hello.txt", "notes.txt")
g("commit", "-q", "-m", "seed: first")
# commit two: notes.txt grows
open(os.path.join(work, "notes.txt"), "w").write("one\ntwo\nthree\n")
g("add", "notes.txt")
g("commit", "-q", "-m", "seed: second")
# staged add: staged.txt (A in the index, not in HEAD)
open(os.path.join(work, "staged.txt"), "w").write("staged line\n")
g("add", "staged.txt")
# unstaged edit: hello.txt (index keeps the HEAD version)
open(os.path.join(work, "hello.txt"), "w").write("alpha\nomega\ngamma\n")
# untracked debris
open(os.path.join(work, "loose.txt"), "w").write("untracked\n")

porcelain = subprocess.check_output([git, "status", "--porcelain"], cwd=work,
                                    text=True).splitlines()
# col0 = index, col1 = worktree: staged.txt is A (index), hello.txt is
# " M" (worktree edit only), loose.txt is "??.
want = ["A  staged.txt", " M hello.txt", "?? loose.txt"]
if sorted(porcelain) != sorted(want):
    sys.exit("go-gitui: seed status %r != %r" % (porcelain, want))
log = subprocess.check_output([git, "log", "--format=%s"], cwd=work,
                              text=True).splitlines()
if log != ["seed: second", "seed: first"]:
    sys.exit("go-gitui: seed log %r" % (log,))

# Stay LOOSE — the two measured guest bounds from deliverable 4 (#1645):
# pack filenames (50 bytes) exceed vi.DirEntry.Name[32] and pack paths
# (76 bytes) exceed file_table.max_path_len (64), so the guest can neither
# enumerate nor open packs. Verify the loose layout the reader will
# actually use, including the64-byte path arithmetic, right here.
head_sha = subprocess.check_output([git, "rev-parse", "HEAD"], cwd=work,
                                   text=True).strip()
obj = os.path.join(work, ".git", "objects", head_sha[:2], head_sha[2:])
if not os.path.exists(obj):
    sys.exit("go-gitui: HEAD object not loose at %s" % obj)
rel = "/host/R/.git/objects/" + head_sha[:2] + "/" + head_sha[2:]
if len(rel) > 64:
    sys.exit("go-gitui: object path %d bytes > 64: %s" % (len(rel), rel))

# Every object in the fixture must fit the guest bound too.
all_objects = subprocess.check_output(
    [git, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)"],
    cwd=work, text=True).split()
for sha in all_objects:
    p = "/host/R/.git/objects/" + sha[:2] + "/" + sha[2:]
    if len(p) > 64:
        sys.exit("go-gitui: object path over 64 bytes: %s" % p)

dest = os.path.join(share, "R")
shutil.rmtree(dest, ignore_errors=True)
shutil.copytree(work, dest)
print("go-gitui: seeded /host/R (%d loose objects; HEAD %s)"
      % (len(all_objects), head_sha[:7]))
PY

# --- run 01: status view, then an M73i click on the `log` tab ------------
vgate_run 01 -- \
    --screen '$RUN_DIR/gitui-status-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords '1' \
    --input-chords-after 'gitui: ready' \
    --screenshot-after 'gitui: view status' \
    --pointer-virtio '124,52,c' \
    --pointer-virtio-after 'gitui: repainted' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gitui: mouse b=32' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'dui: windows=' \
    --script-expect 'gitui: close' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOGITUI.ELF'
vgate_assert 01 serial-contains 'gitui: repo /host/R'
vgate_assert 01 serial-contains 'gitui: status staged=1 modified=1 untracked=1'
vgate_assert 01 serial-contains 'gitui: entry A staged.txt'
vgate_assert 01 serial-contains 'gitui: entry M hello.txt'
vgate_assert 01 serial-contains 'gitui: entry ? loose.txt'
vgate_assert 01 serial-contains 'gitui: log n=2'
vgate_assert 01 serial-contains 'gitui: subject seed: second'
vgate_assert 01 serial-contains 'gitui: subject seed: first'
vgate_assert 01 serial-contains 'gitui: diff hello.txt'
vgate_assert 01 serial-contains 'gitui: diff staged.txt'
vgate_assert 01 serial-contains 'gitui: open id='
vgate_assert 01 serial-contains 'gitui: attached'
vgate_assert 01 serial-contains 'gitui: painted'
vgate_assert 01 serial-contains 'gitui: ready'
vgate_assert 01 serial-contains 'gitui: key 1'
vgate_assert 01 serial-contains 'gitui: view status'
vgate_assert 01 serial-contains 'gitui: repainted'
# M73i: press and release over the tab strip, both reported to the app,
# and the release on `log` switches the view (repaint follows).
vgate_assert 01 serial-contains 'gitui: mouse b=0 x=12 y=1'
vgate_assert 01 serial-contains 'gitui: mouse b=32 x=12 y=1'
vgate_assert 01 serial-contains 'gitui: view log'
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
vgate_assert 01 serial-contains 'gitui: close'
vgate_assert 01 serial-contains 'gitui OK'
vgate_assert 01 serial-absent 'gitui: error'
vgate_assert 01 serial-absent 'SESSION.TXT.FRAMES'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# Window geometry, observed on this seat (not assumed): dui[4] prints the
# declared rect 32,32,640,400 — the 640x400 classic that gives 80 client
# columns, same rect as go-charmhello.
vgate_assert 01 serial-contains 'dui[4]: user user rect=32,32,640,400'

# The status frame: magenta header (app identity), the three status colours
# over their exact rows, and the counts line's digits. Snapshot names are
# the runner's <screen>-after convention (go-charmhello).
vgate_assert 01 snapshot 'gitui-status-screen-after' <<'PY'
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
            up = prev[x]
            row[x] = (row[x] + ((left + up) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

magenta = green = yellow = red = 0
# Counts are cropped to the window's CLIENT area, doubled: dui/pointer
# coordinates are canvas units (1280x720) but this PNG is the 2560x1440
# scanout = 2x. The window is rect 32,32,640,400 with a 16 px title, so
# the client is canvas (32,48)-(672,432) = scanout (64,96)-(1344,864).
# Outside that box the crop would read the boot terminal behind the window
# (measured: its console text tripped every colour floor) and the desktop
# carries ambient colour too (wallpaper green=80143). The window
# composites on top (z=4) inside this crop.
for y in range(96, 864):
    for x in range(64, 1344):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if r > 160 and 60 < g < 190 and b > 160:
            magenta += 1
        if g > 150 and r < 120 and b < 120:
            green += 1
        if r > 200 and g > 200 and b < 120:
            yellow += 1
        if r > 170 and g < 110 and b < 110:
            red += 1
print("gitui status scanout: magenta=%d green=%d yellow=%d red=%d"
      % (magenta, green, yellow, red))
assert magenta >= 60, "GOGITUI header colour absent from scanout"
assert green >= 60, "staged row green absent"
assert yellow >= 60, "modified row yellow absent"
assert red >= 40, "untracked row red absent"
PY

# --- run 02: log view (key '2') ------------------------------------------
vgate_run 02 -- \
    --screen '$RUN_DIR/gitui-log-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/scriptL.txt' \
    --input-chords '2' \
    --input-chords-after 'gitui: ready' \
    --screenshot-after 'gitui: view log' \
    --script2 '$RUN_DIR/scriptL2.txt' \
    --script2-after 'gitui: repainted' \
    --script3 '$RUN_DIR/scriptL3.txt' \
    --script3-after 'dui: windows=' \
    --script-expect 'gitui: close' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded GOGITUI.ELF'
vgate_assert 02 serial-contains 'gitui: ready'
vgate_assert 02 serial-contains 'gitui: key 2'
vgate_assert 02 serial-contains 'gitui: view log'
vgate_assert 02 serial-contains 'gitui: log n=2'
vgate_assert 02 serial-contains 'gitui: subject seed: second'
vgate_assert 02 serial-contains 'gitui: subject seed: first'
vgate_assert 02 serial-contains 'gitui: close'
vgate_assert 02 serial-contains 'gitui OK'
vgate_assert 02 serial-absent 'gitui: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 snapshot 'gitui-log-screen-after' <<'PY'
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
            up = prev[x]
            row[x] = (row[x] + ((left + up) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

magenta = cyan = yellow = red = green = 0
# Counts are cropped to the window's CLIENT area, doubled: dui/pointer
# coordinates are canvas units (1280x720) but this PNG is the 2560x1440
# scanout = 2x. The window is rect 32,32,640,400 with a 16 px title, so
# the client is canvas (32,48)-(672,432) = scanout (64,96)-(1344,864).
# Outside that box the crop would read the boot terminal behind the window
# (measured: its console text tripped every colour floor) and the desktop
# carries ambient colour too (wallpaper green=80143). The window
# composites on top (z=4) inside this crop.
for y in range(96, 864):
    for x in range(64, 1344):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if r > 160 and 60 < g < 190 and b > 160:
            magenta += 1
        if r < 120 and g > 150 and b > 180:
            cyan += 1
        if r > 200 and g > 200 and b < 120:
            yellow += 1
        if r > 170 and g < 110 and b < 110:
            red += 1
        if g > 150 and r < 120 and b < 120:
            green += 1
print("gitui log scanout: magenta=%d cyan=%d yellow=%d red=%d green=%d"
      % (magenta, cyan, yellow, red, green))
assert magenta >= 60, "GOGITUI header colour absent from scanout"
assert cyan >= 40, "log sha cyan absent"
# Exclusivity: the status view's colours must be GONE — the 2J frame swap
# really replaced the view, it did not overlay it.
assert yellow == 0, "status yellow leaked into the log view"
assert red == 0, "status red leaked into the log view"
assert green == 0, "status/diff green leaked into the log view"
PY

# --- run 03: diff view (key '3') -----------------------------------------
vgate_run 03 -- \
    --screen '$RUN_DIR/gitui-diff-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/scriptD.txt' \
    --input-chords '3' \
    --input-chords-after 'gitui: ready' \
    --screenshot-after 'gitui: view diff' \
    --script2 '$RUN_DIR/scriptD2.txt' \
    --script2-after 'gitui: repainted' \
    --script3 '$RUN_DIR/scriptD3.txt' \
    --script3-after 'dui: windows=' \
    --script-expect 'gitui: close' --timeout 240

vgate_assert 03 serial-contains 'exec: loaded GOGITUI.ELF'
vgate_assert 03 serial-contains 'gitui: ready'
vgate_assert 03 serial-contains 'gitui: key 3'
vgate_assert 03 serial-contains 'gitui: view diff'
vgate_assert 03 serial-contains 'gitui: diff hello.txt'
vgate_assert 03 serial-contains 'gitui: diff staged.txt'
vgate_assert 03 serial-contains 'gitui: close'
vgate_assert 03 serial-contains 'gitui OK'
vgate_assert 03 serial-absent 'gitui: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

vgate_assert 03 snapshot 'gitui-diff-screen-after' <<'PY'
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
            up = prev[x]
            row[x] = (row[x] + ((left + up) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

magenta = green = red = blue = yellow = cyan = 0
# Counts are cropped to the window's CLIENT area, doubled: dui/pointer
# coordinates are canvas units (1280x720) but this PNG is the 2560x1440
# scanout = 2x. The window is rect 32,32,640,400 with a 16 px title, so
# the client is canvas (32,48)-(672,432) = scanout (64,96)-(1344,864).
# Outside that box the crop would read the boot terminal behind the window
# (measured: its console text tripped every colour floor) and the desktop
# carries ambient colour too (wallpaper green=80143). The window
# composites on top (z=4) inside this crop.
for y in range(96, 864):
    for x in range(64, 1344):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if r > 160 and 60 < g < 190 and b > 160:
            magenta += 1
        if g > 150 and r < 120 and b < 120:
            green += 1
        if r > 170 and g < 110 and b < 110:
            red += 1
        if b > 170 and r < 120 and g < 160:
            blue += 1
        if r > 200 and g > 200 and b < 120:
            yellow += 1
        if r < 120 and g > 150 and b > 180:
            cyan += 1
print("gitui diff scanout: magenta=%d green=%d red=%d blue=%d yellow=%d cyan=%d"
      % (magenta, green, red, blue, yellow, cyan))
assert magenta >= 60, "GOGITUI header colour absent from scanout"
assert green >= 40, "diff +line green absent"
assert red >= 40, "diff -line red absent"
assert blue >= 60, "diff hunk-header blue absent"
# Exclusivity: status yellow and log cyan must be gone.
assert yellow == 0, "status yellow leaked into the diff view"
assert cyan == 0, "log cyan leaked into the diff view"
PY
