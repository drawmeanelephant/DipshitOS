# go-wm-seat.spec -- M57a/b/c (issues #1313/#1317/#1318) class-B gate: a Go WM
# (GOTABWM.ELF) registers the kernel render-server seat (slot 65), composites a
# blank desktop, manages its OWN Go windows, and HOSTS GOCALC.ELF (M62h)
# plus NOTE.ELF (M66c; the Zig notepad it replaced is deleted in #1485).
#
# M57a: REGISTER (slot 65 cmd 1), the seam-B scanout grant, and a REQUEST_PRESENT
# loop paced by the kind-18 COMPOSITE_TICK. M57b: the seat's own window
# lifecycle (open, chrome descriptor, a kernel-clamped rect, focus/blur, a
# WM-seam close, the client-death probe). M57c: interop — GOCALC.ELF
# discovers the seat by process name, declares over the WM_RPC
# mailbox, and is focused, given the full viewport, and closed by the seat.
# Zig CALC.BIN is gone (M62h / #1406).
#
# One headless boot arms the GPU, execs GOTABWM.ELF, queries the seat and the
# window registry while both are live, execs GOCALC.ELF under it, and lets the
# program exit cleanly (the kernel unregisters the seat, falling back to the
# shim). Serial markers are the proof; each is printed only after its syscall
# returned.
#
# M59 (issue #1298) note: the COMPILED default is now the Go seat, so this
# spec seeds `wm=none` in its share to keep what it actually proves -- the
# seat's explicit, opt-in registration path -- separate from the default flip
# (go-wm-default.spec owns that). Its "shim at boot" asserts are therefore
# about the seeded setting, not about the out-of-the-box boot.
# M63f (#1463): re-verified green after GOTABWM maxTicks 90 (M73z;
# was 48). No HID here.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# exec-order: assert-proven -- each run ends on a marker only its script prints
# (`rx-gotabwm-ok`, `rx-gotabwm-np-ok`, `rx-gotabwm-chrome-ok`), and every stage
# gate waits on guest output the program, the kernel and the hosted app produce
# (`gotabwm: win focus`, `gotabwm: present`, `wm: unregistered, shim resumed`).
#
# M71c (#1562) adds run 03: the seat's OWN clock/status chrome, on an EMPTY
# strip. Run 01/02 host a full-viewport client that the kernel repaints every
# tick, which covers the bottom-right panel; with no client exec'd the panel is
# the seat's last write and is stable in the capture. The capture is timed to
# `gotabwm: present` because the tick loop is paint -> chromeTick -> present, so
# that marker is the first moment the frame is both painted and flushed
# (capturing on `gotabwm: clock` races the flush and reads a black resource --
# measured 2026-09-21).
# M66c (#1445 retarget, #1485 retirement): the client is NOTE.ELF, the Go
# successor to the Zig notepad, and the Zig binary itself is now GONE. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. The coverage that app alone had moved
# to GOEDIT.ELF (find/goto, the unsaved-decline contract) or GOCOMP.ELF (its
# clipboard+timer composition); the theme-token boots were retired with it.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF
#
# M79a (#1704): the seat is LIVE by default -- no run budget, no auto-close,
# no strip choreography. The bounded M57-era demo is DEMO mode, opted in by
# the PRESENCE of /host/GOTABWM.DEMO; the setup below seeds it so runs 01-04
# drive exactly the choreography they always have. Run 05 REMOVES the trigger
# before exec and proves the product default: the loop ticks PAST the demo
# ceiling (maxTicks 90) with the tab still open, nothing ever says `host
# done`/`tab close`, and the run ends by KILLING the seat -- process exit,
# which still unwinds through the kernel's exit seam (`wm: unregistered`).

vgate_name go-wm-seat "issues #1313/#1317/#1318 M57a+b+c: a Go WM registers the slot-65 seat and HOSTS GOCALC.ELF/NOTE.ELF/GOVIEW.ELF on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the seeded `wm=none` keeps this boot shim-only, then the seat is
# opted in explicitly.
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# Phase 2: forwarded while the program holds its own window and is WAITING for
# the blur. `dui focus 0` (the fixed terminal window) hands focus away, so the
# kernel routes WIN_BLUR to the seat. The `wm` + `dui` queries land while the
# seat's window is live (5 = the four fixed layers + the seat's Go window).
# Then GOCALC.ELF is exec'd under the Go seat.
vgate_file script2.txt <<'EOF'
wm
dui
dui focus 0
exec GOCALC.ELF
EOF

# Phase 3: after the program exits and the kernel unregisters the seat, the
# report is back to the shim and the registry is back to its pre-program count
# (the hosted app closed, the leaked probe window reaped).
vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-ok
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
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M59 (issue #1298): the compiled default is the Go seat now. Seed `wm=none`
# so this boot composites via the shim and the seat arrives only where the
# script asks for it -- the point of THIS spec (go-wm-default.spec owns the
# default-flip proof). `none` is the documented shim-only seat value.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
# M79a (#1704): the demo choreography is opt-in (the trigger's PRESENCE).
# Runs 01-04 drive it, so seed the fixture here; run 05 removes it with
# `vf rm GOTABWM.DEMO` before exec and proves the live default instead.
# A daily session never stages this file and gets the live seat.
with open(os.path.join(share, "GOTABWM.DEMO"), "w") as f:
    f.write("demo\n")
print("seeded GOTABWM.DEMO (seat demo mode: bounded choreography)")
PY

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

# M71h (#1567): run 04 hosts the image viewer, so stage it and the QOI fixture
# it opens. HOST PREREQUISITE: bash tools/go/build-goview.sh -> .build/go/GOVIEW.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOVIEW.ELF")
if not os.path.exists(src):
    sys.exit("GOVIEW.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goview.sh")
shutil.copy(src, os.path.join(share, "GOVIEW.ELF"))
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi", os.path.join(share, "TEST.QOI"))
print("staged GOVIEW.ELF into share (%d bytes) + TEST.QOI" %
      os.path.getsize(os.path.join(share, "GOVIEW.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-ok' --timeout 300

# --- M57a: the seat and the blank desktop --------------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
# The seat is opt-in: the seeded `wm=none` leaves the boot shim-only (the
# autostart reports nothing for that seat), and the run's `wm` query before
# the exec and after the exit both report shim.
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
# The program's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
# The kernel's own report naming the live seat, and the clean teardown.
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-ok'

# --- M57b: the seat's own Go window lifecycle ----------------------------
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win chrome'
vgate_assert 01 serial-contains 'gotabwm: win rect '
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'
vgate_assert 01 serial-contains 'gotabwm: win leak id='
# The kernel CLAMPED the WM's proposed 4000,3000 position to the 1280x720
# scanout: x is min(4000, 1280-256) = 1024, y is min(3000, 720-192) = 528.
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
# While the seat's window is live the registry counts 5 (the four fixed
# terminal/wallpaper/taskbar/dock windows + the seat's Go window).
vgate_assert 01 serial-contains 'dui: windows=5 focused='

# --- M57c: GOCALC.ELF hosted by the Go seat --------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gotabwm: host done'
# No residue: the hosted app closed and the leaked probe window was reaped, so
# the registry is back to the four fixed layers only. The seat's own window sat
# at registry index 4 while it was live (one `dui[4]: user` row in the whole
# run) and there is no index-4 row after exit.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-count 'dui[4]: user' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- M57c run 02: the Go editor NOTE.ELF ---------------------------------
# Same choreography, a Go tab-aware app. If GOCALC hosts and NOTE.ELF does
# not (or vice versa) the interop would be app-specific.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec NOTE.ELF
EOF

vgate_file script3-02.txt <<'EOF'
dui
echo rx-gotabwm-np-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-np-ok' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'exec: loaded NOTE.ELF'
# The same interop chain as CALC, for the second app.
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 02 serial-contains 'gotabwm: host focus id='
vgate_assert 02 serial-contains 'gotabwm: host view id='
vgate_assert 02 serial-contains 'note: resize relayout'
vgate_assert 02 serial-contains 'gotabwm: host close id='
vgate_assert 02 serial-contains 'note: win_close'
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'dui: windows=4 focused='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- M71c (#1562) run 03: the seat's own clock/status chrome ----------------
# The seat is opted in and NO client is exec'd, so the strip is empty: the seat
# paints the full-frame blank desktop plus its panel, and nothing covers
# either. `dui focus 0` still runs because the seat's window phase blocks until
# it loses focus (the M57b choreography).
vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-gotabwm-chrome-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --screenshot-after 'rx-gotabwm-chrome-ok' \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gotabwm: present' \
    --script-expect 'rx-gotabwm-chrome-ok' --timeout 300

vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: scanout'
vgate_assert 03 serial-contains 'gotabwm: holding seat'
vgate_assert 03 serial-absent 'gotabwm: tab open id='
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- M71h (#1567) run 04: the seat HOSTS GOVIEW.ELF ------------------------
# The image viewer is a tabapp client, so its real home is the seat's strip,
# and `gview: tab-aware (full-viewport)` plus the resize line are the app's own
# half of deliverable 1 (paint full-viewport in GOTABWM). live-image-viewer
# owns the decoding and both error surfaces; this run owns the hosting: the
# declare is accepted, the canvas is the seat's own 1100x692 viewport, and the
# seat closes the tab (its single-tab budget) and the app exits cleanly.
vgate_file script-04.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
dui focus 0
exec GOVIEW.ELF /host/TEST.QOI
EOF

vgate_file script3-04.txt <<'EOF'
dui
echo rx-gotabwm-view-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-view-ok' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'exec: loaded GOVIEW.ELF'
vgate_assert 04 serial-contains 'gotabwm: rpc declare id='
vgate_assert 04 serial-contains 'gview: tab-aware (full-viewport)'
vgate_assert 04 serial-contains 'gview: loaded TEST.QOI 160x120 QOI bytes=340'
vgate_assert 04 serial-contains 'gotabwm: host focus id='
vgate_assert 04 serial-contains 'gotabwm: host view id='
vgate_assert 04 serial-contains 'gview: resize relayout 1280x720'
vgate_assert 04 serial-contains 'gotabwm: host close id='
vgate_assert 04 serial-contains 'gview: win_close'
# WIN_CLOSE is the path the seat drives, and Zig VIEW.BIN's rule for it is
# `view: win_close` + exit 43 with no `exiting 43` line (that line belongs to
# the app's own quit path). The status is the kernel's own report.
vgate_assert 04 serial-contains 'tasks user-exec exited status=43'
vgate_assert 04 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 04 serial-contains 'dui: windows='
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# The request is the aspect-fitted 328x264; the GRANTED canvas is the seat's
# scanout (1280x720), which is what "full-viewport" means here. Both must
# appear, in that order, or the app never relayouted.
req = ser.find("gview: open id")
grant = ser.find("gview: resize relayout 1280x720")
assert req >= 0 and grant >= 0, "missing the open or the granted-canvas marker"
assert req < grant, "the resize marker must follow the open marker"
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), "open dimension check failed"
PY

# The face and its source: the marker is one-shot and comes after the seat
# registered, so a gate never has to guess which of VZ's three cases (kernel
# EFI epoch / host `.clock` / uptime) this boot is in.
vgate_assert 03 serial-contains 'gotabwm: clock-source '
vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
src = re.search(r"(?m)^gotabwm: clock-source (kernel|host|uptime)$", ser)
if not src:
    sys.exit("no well-formed gotabwm: clock-source line (want kernel|host|uptime)")
face = re.search(r"(?m)^gotabwm: clock (\d\d):(\d\d):(\d\d)$", ser)
if not face:
    sys.exit("no well-formed gotabwm: clock HH:MM:SS line")
h, mi, sec = (int(g) for g in face.groups())
if mi > 59 or sec > 59:
    sys.exit("clock face out of range: %s" % face.group(0))
if h > 99:
    sys.exit("clock hours past 99: %s" % face.group(0))
reg = ser.find("gotabwm: registered")
src_i, face_i = src.start(), face.start()
if not (0 <= reg < src_i < face_i):
    sys.exit("clock markers out of order (registered=%d source=%d face=%d)"
             % (reg, src_i, face_i))
if ser.count("gotabwm: clock-source ") != 1:
    sys.exit("the clock-source marker is one-shot, saw %d"
             % ser.count("gotabwm: clock-source "))
print("clock source=%s face=%02d:%02d:%02d (one-shot, after registered)"
      % (src.group(1), h, mi, sec))
PY

# THE chrome pixel assert: the panel's own rect on the SAME frame. The rect is
# chromeRect(1280,720) = ChromeW 148 x ChromeH 20 inset 8 -> (1124,692); the
# probe scales with the capture. Thresholds are the seat's own tokens, and the
# exclusion is the point: the blank desktop is theme Bg (0x182026) and the
# kernel terminal is 0x101418 with 0x00ff00 text, so neither can satisfy a
# ChromeBg-modal panel with no console-green in it. Reported margins came in at
# modal 7848/11840 pixels and >= 3 distinct colours (measured 2026-09-21).
vgate_assert 03 snapshot 'screen-03-after' <<'PY'
import sys, zlib, struct
from collections import Counter
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
x0, y0, pw, ph = 1124, 692, 148, 20
# seat theme tokens: ChromeBg 0x11171c, Ink 0xe6edf3; the kernel terminal is
# 0x101418 bg with 0x00ff00 text. The capture applies a small colour-space
# shift, hence the tolerances below (measured: ChromeBg reads 0x12171c).
chrome_bg = (0x11, 0x17, 0x1c)
modal = Counter(); ink = green = total = 0
for y in range(int(y0 * scale), int((y0 + ph) * scale)):
    for x in range(int(x0 * scale), int((x0 + pw) * scale)):
        r, g, b = px(x, y)
        total += 1
        modal[(r, g, b)] += 1
        if min(r, g, b) >= 150:
            ink += 1
        if g > 150 and r < 120 and b < 120:
            green += 1
best, best_n = modal.most_common(1)[0]
dist = max(abs(best[0]-chrome_bg[0]), abs(best[1]-chrome_bg[1]),
           abs(best[2]-chrome_bg[2]))
print("panel rect %dx%d (%d px): modal=#%02x%02x%02x n=%d distinct=%d "
      "ink=%d console-green=%d"
      % (int(pw*scale), int(ph*scale), total,
         best[0], best[1], best[2], best_n, len(modal), ink, green))
assert dist <= 4, ("the panel rect is not the seat's ChromeBg (modal #%02x%02x%02x "
                   "is %d off 0x11171c) - the panel was not painted"
                   % (best[0], best[1], best[2], dist))
assert best_n >= 3000, ("only %d/%d panel-rect pixels are ChromeBg - the panel "
                        "is not covering its rect" % (best_n, total))
assert len(modal) >= 3, ("the panel rect holds only %d colour(s) - no rule and "
                         "no glyphs, so the chrome is a bare fill" % len(modal))
assert ink >= 20, ("only %d ink-white pixels in the panel rect - the clock face "
                   "did not paint" % ink)
assert green == 0, ("%d console-green pixels inside the panel rect - the kernel's "
                    "terminal is compositing over the seat's scanout" % green)
PY

# --- M79a (#1704) run 05: LIVE mode persistence --------------------------
# Runs 01-04 opt into the bounded demo (the seeded trigger). This run removes
# the trigger BEFORE exec, so the seat runs its product default: no run
# budget, no auto-close, no choreography. It hosts GOCALC.ELF and simply keeps
# going; `gotabwm: live steady tabs=` prints only once the loop has ticked
# PAST the demo ceiling (maxTicks = 90), and the run then KILLS the seat
# (process exit -- the kernel's exit seam still tears it down, M52). Nothing
# may say `host done`, `tab close id=`, `host close id=`, or `gocalc: close`.
vgate_file script-live.txt <<'EOF'
vf rm GOTABWM.DEMO
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-live.txt <<'EOF'
dui
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script3-live.txt <<'EOF'
kill GOTABWM.ELF
wm
echo rx-gotabwm-live-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-live' \
    --script '$RUN_DIR/script-live.txt' \
    --script2 '$RUN_DIR/script2-live.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-live.txt' \
    --script3-after 'gotabwm: live steady ' \
    --script-expect 'rx-gotabwm-live-ok' --script-expect-tail 30 --timeout 420

vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-absent 'gotabwm: mode demo'
vgate_assert 05 serial-contains 'gotabwm: registered'
vgate_assert 05 serial-contains 'gotabwm: holding seat'
vgate_assert 05 serial-contains 'gotabwm: present'
vgate_assert 05 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 05 serial-contains 'gotabwm: rpc declare id='
vgate_assert 05 serial-contains 'gocalc: declare accepted'
vgate_assert 05 serial-contains 'gotabwm: host view id='
vgate_assert 05 serial-contains 'gotabwm: tab open id='
# The loop outlived the old ceiling, and the tab survived it: the steady
# marker prints only at tick maxTicks+1, nothing auto-closed before then, and
# the absent asserts below pin that nothing closed after.
vgate_assert 05 serial-contains 'gotabwm: live steady tabs='
vgate_assert 05 serial-count 'gotabwm: tick' 91
vgate_assert 05 serial-absent 'gotabwm: host close id='
vgate_assert 05 serial-absent 'gotabwm: tab close id='
vgate_assert 05 serial-absent 'gotabwm: host done'
vgate_assert 05 serial-absent 'gocalc: close'
vgate_assert 05 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 05 serial-contains 'rx-gotabwm-live-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
