# go-dogfood.spec -- M69a (issue #1528) class-B gate: the daily-driver beat on
# the DEFAULT Go seat (no `wm` override anywhere in this spec).
#
# Two boots, one beat. Each boot stages a slice of the beat's apps on the same
# default seat, and each slice is phase-gated: the harness forwards the next
# `exec` only after the previous app's own marker says it was HOSTED, so the
# serial order is the beat order and not the scheduler's. The six markers are
# printed by guest programs -- the seat and the apps themselves -- so no staged
# line and no harness echo can produce one (D2).
#
#   boot 01   exec GOSH.ELF -> exec NOTE.ELF        seat, gosh, note, ok
#   boot 02   exec GOCALC.ELF -> exec WEB.ELF PAGE  seat, calc, page, ok
#
# WHY TWO BOOTS, not one (both limits observed in-tree, neither invented here):
#
#  1. The runner forwards at most THREE command phases per boot (`--script`,
#     `--script2`, `--script3`, each released by its own `-after` marker --
#     host/vm-runner/Sources/VMRunner/main.swift). Four phase-gated execs need
#     four phases. Putting two execs in one phase would leave their declare
#     order to the scheduler, and an ordered assert on a race is a flake, not
#     evidence.
#  2. The seat's PROVEN envelope is three Go runtimes: itself plus two clients
#     (M65d / #1442: 3 kernel + 3x4 Ms + 1 spare; see the maxTicks note in
#     user/go/gotabwm/seat.go). That is an envelope, not a documented failure --
#     four live Go runtimes have not been tried, and #1449 is the record of a
#     different shape entirely (a THIRD SEQUENTIAL exec from one EL0 parent,
#     which M70c-S2 then measured as unreproduced at its head). So each boot
#     stages two client apps, which is also the shape go-wm-default (one app)
#     and go-wm-tabs (two) already prove. Reason 1 alone is a hard limit; this
#     one is the conservative choice inside a proven envelope, and is labelled
#     as such rather than cited as a wall.
#
# The beat is therefore a tour of the default seat: shell+editor together,
# then calculator+browser together. All four apps, one seat, same share.
#
# What each marker actually proves -- stated precisely, because the obvious
# reading of the app markers is stronger than the wire supports:
#
#   dogfood: seat   the seat's own line, after registration AND the one-seat
#                   probe returned: the DEFAULT seat owns the desktop.
#   dogfood: gosh   the APP, on its accepted-declare path only. Read this for
#   dogfood: note   what it is: the seat ANSWERED the declare with the ack's
#   dogfood: calc   applied bit set, i.e. a WM seat is there and the app is on
#                   it -- NOT proof that a tab opened. gotabwm's applyRPC acks
#                   applied=1 on this path whether or not tabs.OpenTab took
#                   (interop.go), and the app cannot see the difference, so
#                   these three lines must not be asked to carry the hosting.
#   dogfood: page   WEB, once, on the first frame of a LAID-OUT page reaching
#                   the scanout -- the page rendered.
#   dogfood: ok     the seat's host-done line, printed only when this boot
#                   actually hosted a tab: the dogfoodHosted latch is set by a
#                   successful tabs.OpenTab alone (interop.go).
#
# HOSTING is therefore pinned where the kernel-side truth lives: the seat's own
# `gotabwm: tab open id=` counter, asserted at TWO per boot below -- the idiom
# go-wm-tabs.spec uses for the same two-tab property. Without that count the
# gate could regress to one hosted app per boot and still pass, since one tab
# sets the latch that `dogfood: ok` hangs on and every app marker above would
# still fire.
#
# The browser is attached with WM_RPC kind 5 (attach), not kind 8
# (declare_fullscreen), so the page keeps the 512x384 geometry the live-web
# gates pin. Attach is what makes the page VISIBLE here: the seat paints the
# blank desktop only while its strip is empty, and that compose-N fill sits
# ABOVE user windows -- an undeclared browser would be silently overpainted.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh        ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh           ->  .build/go/GOSH.ELF
#   bash tools/go/build-note.sh           ->  .build/go/NOTE.ELF
#   bash tools/go/build-gocalc.sh         ->  .build/go/GOCALC.ELF
#   bash tools/go/build-web.sh browser    ->  .build/go/WEB.ELF (the name the
#                                             app claims to the WM; the script
#                                             defaults it now)
#   (the page is the pinned fixture user/go/browser/testdata/gate-page.html,
#    staged as /host/DOGFOOD.HTML; no new fixture)
#
# M69b subscribes to the same six markers for its `--screenshot-after`; see
# docs/testing.md.
#
# M69g (#1558) adds a THIRD boot: GOSH ALONE on the same default Go seat,
# captured after a settle, with a PIXEL assert on its first terminal line.
# The two boots above are marker-only by design; a tab that renders nothing is
# invisible to every one of them, which is exactly how #1558 escaped. Boot 03
# is the falsifiable half — the seed, the seat and the shell are the same, and
# only GOSH is hosted, so the captured frame's tab region is the shell's own
# pixels and nothing else.
#
# exec-order: assert-proven -- every phase gate is anchored on guest output
# (the seat's or an app's own marker) and each run ends on a marker only its
# stage script prints (`rx-dogfood-01-ok` / `rx-dogfood-02-ok`).

vgate_name go-dogfood "issue #1528 M69a: the DEFAULT Go seat hosts the daily-driver beat (GOSH+NOTE, then GOCALC+WEB) with ordered guest-printed dogfood: markers"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# --- boot 01: the shell and the editor on the default seat -----------------
# Phase 1 is released by the seat's own `dogfood: seat`, so GOSH starts only
# once the default seat is live and exclusive.
vgate_file script-01a.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF
EOF

# Phase 2 waits on GOSH's `dogfood: gosh`: the shell is HOSTED as a GOTABWM
# tab before the editor is launched at all.
vgate_file script-01b.txt <<'EOF'
exec NOTE.ELF
EOF

# Phase 3 waits on the seat's `dogfood: ok` (host-done), so the beat slice has
# finished before the run ends; the end marker itself is script-owned.
vgate_file script-01c.txt <<'EOF'
echo rx-dogfood-01-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOTABWM.ELF", "build-gotabwm.sh"),
                  ("GOSH.ELF", "build-gosh.sh"),
                  ("NOTE.ELF", "build-note.sh"),
                  ("GOCALC.ELF", "build-gocalc.sh"),
                  ("WEB.ELF", "build-web.sh browser WEB")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
shutil.copy(os.path.join("user", "go", "browser", "testdata", "gate-page.html"),
            os.path.join(share, "DOGFOOD.HTML"))
# The whole point of this spec is the COMPILED default seat: a persisted `wm`
# row would test the setting instead of the daily driver.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; the dogfood beat must "
             "boot with no persisted `wm`")
print("staged GOTABWM/GOSH/NOTE/GOCALC/WEB + DOGFOOD.HTML from the pinned "
      "gate-page.html fixture")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-01b.txt' \
    --script2-after 'dogfood: gosh' \
    --script3 '$RUN_DIR/script-01c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-01-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The DEFAULT seat, chosen by the compiled default and nothing else.
vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
# dogfood: seat -- the seat's own announcement, after both returned.
vgate_assert 01 serial-contains 'dogfood: seat'

# --- GOSH, HOSTED as a GOTABWM tab (not Zig TABWM) --------------------------
vgate_assert 01 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'dogfood: gosh'
vgate_assert 01 serial-contains 'gotabwm: tab open id='
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='

# --- NOTE, the same seat, the same strip -----------------------------------
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'dogfood: note'

# --- the slice's own close, then the run's end marker ----------------------
vgate_assert 01 serial-contains 'gotabwm: host done'
vgate_assert 01 serial-contains 'dogfood: ok'
vgate_assert 01 serial-contains 'rx-dogfood-01-ok'
# THE central property of this gate, and the one no app marker can carry: TWO
# tabs opened on the one strip. Read `gotabwm: tab open id=` (printed only when
# tabs.OpenTab returned true) at least twice -- the idiom go-wm-tabs.spec uses
# (lines 185/446). Without it, a regression to one hosted app per boot would
# pass every assert above: one OpenTab sets the dogfoodHosted latch `dogfood:
# ok` hangs on, and each app's own marker fires off the ack alone.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 2
# The Zig fallback seat's autostart line is what this rules out at runtime (the
# line-start check in the python block covers its own marker). It guards the
# compiled `wm_default` constant rather than the seat's behaviour, so read it as
# "the default was compiled in", not as "the fallback engine ran".
# NOT `serial-absent 'tabwm: registered'`: that is a SUBSTRING match (grep -F)
# and `gotabwm: registered` contains it, so the assert could never pass.
vgate_assert 01 serial-absent 'wm: autostart tabwm'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The order, at LINE START (a staged line that merely contains a marker cannot
# satisfy it -- the same reason go-sh.spec anchors its typed markers). The
# second half of the beat must be ABSENT from this boot: without that, a run
# that printed every marker off one app could pass as an ordered beat.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: gosh", "dogfood: note", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: calc", "dogfood: page"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the shell/editor boot")
# The Zig seat's own marker, at line start: `serial-absent 'tabwm: registered'`
# is unusable here because `gotabwm: registered` contains it.
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 01 order ok: " + " < ".join(want) +
      " (and the calculator/browser half is absent)")
PY

# D1, re-checked between the boots (the staging guard only saw the pre-run
# share). Boot 01 must not have left a `wm` row behind: the moment it does, boot
# 02 tests the SETTING while every assert it makes still passes.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
p = os.path.join(share, "SETTINGS.TXT")
if os.path.exists(p):
    rows = [l for l in open(p, errors="replace").read().splitlines()
            if l.strip().startswith("wm=")]
    if rows:
        sys.exit("FAIL: boot 01 persisted a `wm` row (%s) - boot 02 would boot "
                 "the SETTING, not the compiled default seat" % rows)
    print("between the boots: SETTINGS.TXT exists and carries no `wm` row, so "
          "boot 02 boots the compiled default")
else:
    print("between the boots: no SETTINGS.TXT on the share at all, so boot 02 "
          "boots the compiled default")
PY

# --- boot 02: the calculator and the browser on the same default seat -------
# Same share, same compiled default. D1 says the seat is the COMPILED default
# and not a setting, and boot 02 is the boot where that could silently stop
# being true: if anything ever began persisting a `wm` row, boot 01 would write
# it, boot 02 would boot from the setting, and every assert in this run would
# still pass. So the share is re-checked BETWEEN the two boots rather than
# trusting the staging guard, which only ever saw the pre-run share.
vgate_file script-02a.txt <<'EOF'
set GOMAXPROCS=1
exec GOCALC.ELF
EOF

vgate_file script-02b.txt <<'EOF'
exec WEB.ELF /host/DOGFOOD.HTML
EOF

vgate_file script-02c.txt <<'EOF'
echo rx-dogfood-02-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'dogfood: calc' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-02-ok' --timeout 300

vgate_assert 02 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'dogfood: seat'

# --- GOCALC, hosted ---------------------------------------------------------
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'gocalc: declare accepted'
vgate_assert 02 serial-contains 'dogfood: calc'

# --- WEB shows a page, on the seat's own strip ------------------------------
vgate_assert 02 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 02 serial-contains 'web: url /host/DOGFOOD.HTML'
vgate_assert 02 serial-contains 'web: parse nodes='
vgate_assert 02 serial-contains 'web: layout blocks='
vgate_assert 02 serial-contains 'web: paint items='
vgate_assert 02 serial-contains 'dogfood: page'
vgate_assert 02 serial-contains 'web: ready'
# The attach (kind 5) the browser sends, acknowledged by the seat: the page is
# on the strip -- the only arrangement in which the seat stops blanking over it.
vgate_assert 02 serial-contains 'gotabwm: rpc attach id='
vgate_assert 02 serial-contains 'gotabwm: tab open id='

vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'dogfood: ok'
vgate_assert 02 serial-contains 'rx-dogfood-02-ok'
# Two tabs again -- the calculator's declare and the browser's attach. See boot
# 01 for why this count, and not the app markers, is the hosting proof.
vgate_assert 02 serial-count 'gotabwm: tab open id=' 2
# See boot 01: `tabwm: registered` is a substring of `gotabwm: registered`.
vgate_assert 02 serial-absent 'wm: autostart tabwm'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: calc", "dogfood: page", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: gosh", "dogfood: note"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the calculator/browser boot")
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 02 order ok: " + " < ".join(want) +
      " (and the shell/editor half is absent)")
PY

# --- boot 03: the shell tab's PIXELS on the default seat (M69g, #1558) ------
# Same compiled default seat, same share, GOSH alone. The capture is released
# by a MONITOR echo 4 s after `gosh: prompt` (the M69b recipe: the prompt is
# written to the tty, and the compositor paints it on the next composite), so
# the frame holds a settled tab rather than the boot frame.
#
# What the marker asserts is the geometry, not just "it ran": GOSH declares
# full-viewport, so its window is the whole scanout, and the kernel draws a
# window-bound terminal's grid starting at its title-band height (16 device
# rows). The shell's fresh prompt is therefore the ONLY text on the first
# grid line, at device y 16..31 (M73l #1661: cell_h=16 — was 16..23 at
# 8px cells). Before the #1558 fix GOTABWM's own 96x64
# client-death probe window (8,8,96,64) painted its chrome over that band and
# the region held no terminal-green pixels at all (measured: 55, all of it
# anti-aliasing from the probe's own white title text); with the fix it holds
# the prompt (measured: 578 across repeats).
vgate_file script-03a.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF
EOF

vgate_file script-03b.txt <<'EOF'
echo shot-gosh-pixels
EOF

vgate_file script-03c.txt <<'EOF'
echo rx-dogfood-03-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --screenshot-after 'shot-gosh-pixels' \
    --script '$RUN_DIR/script-03a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-03b.txt' \
    --script2-after 'gosh: prompt' --script2-delay 4 \
    --script3 '$RUN_DIR/script-03c.txt' \
    --script3-after 'shot-gosh-pixels' \
    --script-expect 'rx-dogfood-03-ok' --timeout 300

vgate_assert 03 serial-contains 'dogfood: seat'
vgate_assert 03 serial-contains 'gotabwm: tab open id='
vgate_assert 03 serial-contains 'gosh: prompt'
vgate_assert 03 serial-contains 'rx-dogfood-03-ok'
vgate_assert 03 serial-absent 'wm: autostart tabwm'
vgate_assert 03 serial-absent '[EXC] parking:'

# THE pixel assert. Scale the capture (the window capture is 2x the 1280x720
# scanout) instead of pinning counts to one backing scale, and count only
# GREEN-dominant pixels: the probe window's chrome that used to occupy this
# band is white-on-grey, so a chrome-green tint cannot pass this by accident.
vgate_assert 03 snapshot 'screen-03-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

scale = w / 1280.0
# The tab's first terminal line: device rows 17..29 (inside the 16-row
# grid cell that starts at the kernel's 16-row title band — M73l #1661
# cell_h=16), columns 1..55 — the
# "gosh> " prompt and its block cursor.
green = 0
for y in range(int(17 * scale), int(30 * scale)):
    for x in range(int(1 * scale), int(56 * scale)):
        r, g, b = px(x, y)
        if g > r + 30 and g > b + 30:
            green += 1
print("terminal-green pixels on the tab's first line: %d" % green)
assert green >= 200, ("GOSH's tab shows no prompt text (%d green pixels on "
                      "the first terminal line) - the tab is blank" % green)
PY
