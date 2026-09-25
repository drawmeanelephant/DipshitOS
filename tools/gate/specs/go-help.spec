# go-help.spec -- M74c (issue #1646): GOHELP.ELF is a Bubble Tea TUI over
# the bound /dev/tty. Run 01 group-jumps through the GOSH catalog, browses
# the seeded /host/docs bundle, filters with `/`, and opens a full detail
# page whose exact truecolour accent is asserted from the raw BGRX scanout
# streamed over custom virtio. Run 02 opens the M79f in-app desktop-shortcut
# sheet and returns to the catalog.
#
# Shape: go-charmhello / go-fileman — direct exec on the kernel desktop
# (no `tabwm start` seat), native 512x384 window = the kernel grid's 64x46
# client (cols <= the grid's 80-col cap), chords over the real HID path,
# `dui` rect proof, and a raw scanout snapshot after the app's post-detail
# marker.
#
# Marker discipline is load-bearing: the app flushes each frame's markers
# only AFTER painting it. The custom-virtio snapshot waits on
# `gohelp: settled after detail`, one post-paint yield after the detail frame;
# script3 uses the same barrier plus a two-second delay so the raw scanout is
# captured before teardown.
#
# exec-order: assert-proven -- the run ends on `rx-gohelp-ok`, which only
# script3 prints, and script3 waits on the app's own settle marker; an app
# that never ran, never opened a detail, or never settled cannot pass.

vgate_name go-help "M74c #1646 + M79f #1717: GOHELP.ELF group-jumps, shows desktop shortcuts, browses /host/docs and pixel-asserts a detail page over the bound tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOHELP.ELF
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gohelp-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOHELP.ELF")
if not os.path.exists(src):
    sys.exit("GOHELP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-help.sh")
shutil.copy(src, os.path.join(share, "GOHELP.ELF"))
docs = os.path.join(share, "docs")
os.makedirs(docs, exist_ok=True)
guide = os.path.join(docs, "GUIDE.TXT")
with open(guide, "w") as f:
    f.write("virelai help docs fixture\n")   # 26 bytes: pinned in serial assert
notes = os.path.join(docs, "NOTES.MD")
with open(notes, "w") as f:
    f.write("pinned help fixture two\n")     # 24 bytes
print("staged GOHELP.ELF into share (%d bytes), %s (%d bytes), %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOHELP.ELF")),
       guide, os.path.getsize(guide), notes, os.path.getsize(notes)))
PY

# The chord batch, in full (12 strokes at the cv-input transport's fixed
# 0.25 s): hop right to the files group head, hop left back to shell, open
# the docs bundle, read its first page, back out to browse, arm `/`, type
# `ec` (pinned n=3: echo, secrets, exec), escape to clear, move onto echo,
# open the full detail — the LAST stroke, so the snapshot barrier and the
# dui script both fire against an idle app.
vgate_run 01 -- \
    --screen '$RUN_DIR/help-screen' \
    --input --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --snapshot-after 'gohelp: settled after detail' \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'right,left,d,return,backspace,backspace,/,e,c,escape,down,return' \
    --input-chords-after 'gohelp: ready' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gohelp: detail echo usage=echo [ARG...]' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gohelp: settled after detail' \
    --script3-delay 2 \
    --script-expect 'rx-gohelp-ok' --timeout 240

# --- serial: the app ran, jumped, browsed, filtered, opened a detail -------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOHELP.ELF'
vgate_assert 01 serial-contains 'gohelp: open id='
vgate_assert 01 serial-contains 'gohelp: attached'
vgate_assert 01 serial-contains 'gohelp: painted'
vgate_assert 01 serial-contains 'gohelp: ready'
vgate_assert 01 serial-contains 'gohelp: present'

# The catalog came from shlib.HelpRows — single-sourced from GOSH's
# helpCatalog (n=44 is the drift tripwire; model_test.go pins the same
# number on the host), and the seeded docs bundle is visible.
vgate_assert 01 serial-contains 'gohelp: catalog n=44'
vgate_assert 01 serial-contains 'gohelp: docs n=2'

# The window itself: native rect on the kernel desktop (dui from script2,
# fired at the detail barrier, so it describes the live window) — the
# charmhello/fileman dui row shape.
vgate_assert 01 serial-contains 'dui[4]: user user rect=32,32,512,384'

# Group navigation: right lands on the files head (ASCII sorts `.` before
# the letters — observed), left hops back to the shell head.
vgate_assert 01 serial-contains 'gohelp: focus . group=files'
vgate_assert 01 serial-contains 'gohelp: focus clear group=shell'

# Docs section: the seeded bundle's first page read whole (26 bytes).
vgate_assert 01 serial-contains 'gohelp: docs open'
vgate_assert 01 serial-contains 'gohelp: docfocus GUIDE.TXT'
vgate_assert 01 serial-contains 'gohelp: doc GUIDE.TXT bytes=26'

# Back to browse, then `/`-to-filter: `ec` matches exactly three rows
# (echo, secrets, exec — pinned in model_test.go), escape clears to the
# full catalog.
vgate_assert 01 serial-contains 'gohelp: browse'
vgate_assert 01 serial-contains 'gohelp: filter on'
vgate_assert 01 serial-contains 'gohelp: filter ec n=3'
vgate_assert 01 serial-contains 'gohelp: filter cleared n=44'

# Key labels line up with the chord table verbatim.
vgate_assert 01 serial-contains 'gohelp: key d'
vgate_assert 01 serial-contains 'gohelp: key /'
vgate_assert 01 serial-contains 'gohelp: key escape'

# The detail page the screenshot captures: name, then the usage line the
# barrier sequences on.
vgate_assert 01 serial-contains 'gohelp: focus echo group=shell'
vgate_assert 01 serial-contains 'gohelp: detail echo usage=echo [ARG...]'
vgate_assert 01 serial-contains 'gohelp: settled after detail'

# Clean teardown through the window-close path.
vgate_assert 01 serial-contains 'gohelp: close'
vgate_assert 01 serial-contains 'gohelp OK'
vgate_assert 01 serial-contains 'rx-gohelp-ok'

# --- serial: the refusals that must NOT happen ------------------------------
vgate_assert 01 serial-absent 'gohelp: no /dev/tty'
vgate_assert 01 serial-absent 'gohelp: attach failed'
vgate_assert 01 serial-absent 'gohelp: doc error'
# M73i selection precedence: with ?1000/?1006 enabled, a plain pointer
# never falls through to kernel selection.
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- scanout: the detail page's exact accent in the REAL framebuffer -------
# The barrier is `settled after detail`, printed after the detail frame paints
# and yields once. The custom-virtio kind-4 stream returns the guest's raw
# 1280x720 BGRX scanout, avoiding host compositor/ScreenCaptureKit timing.
# The native GOHELP window is at (32,32) 512x384; its 16 px title places the
# terminal client at y=48. The final detail frame's status and hint rows sit
# at y=384..416. Their exact truecolour proves the guest VT consumed the final
# GOHELP frame; render_test.go separately pins the detail name/usage/blurb
# strings and accent, so this class-B check is deterministic without decoding
# host-compositor pixels.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(data) != W * H * 4:
    sys.exit("unexpected BGRX snapshot size %d" % len(data))

# Custom virtio writes B,G,R,X. The detail status uses colStat
# (255,200,80) and its hint uses colDim (120,130,144).
status = 0
hint = 0
for y in range(384, 416):
    for x in range(32, 544):
        k = (y * W + x) * 4
        b, g, r = data[k], data[k + 1], data[k + 2]
        if (r, g, b) == (255, 200, 80):
            status += 1
        elif (r, g, b) == (120, 130, 144):
            hint += 1
print("gohelp custom-virtio scanout: status=%d hint=%d" % (status, hint))
assert status >= 60, "GOHELP detail status colour absent from raw BGRX scanout"
assert hint >= 120, "GOHELP detail hint colour absent from raw BGRX scanout"
PY

# --- run 02: the M79f desktop-shortcut cheat sheet -----------------------
# A separate boot keeps the established detail screenshot choreography (and
# its timing) byte-for-byte. `s` paints the shortcut page; the marker is
# flushed only after that frame exists. Backspace returns to the catalog and
# the script-only close marker ends the boot.
vgate_run 02 -- \
    --screen '$RUN_DIR/help-shortcuts-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords 's,backspace' \
    --input-chords-after 'gohelp: ready' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gohelp: shortcuts' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gohelp: browse' \
    --script-expect 'rx-gohelp-ok' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded GOHELP.ELF'
vgate_assert 02 serial-contains 'gohelp: open id='
vgate_assert 02 serial-contains 'gohelp: attached'
vgate_assert 02 serial-contains 'gohelp: ready'
vgate_assert 02 serial-contains 'gohelp: shortcuts'
vgate_assert 02 serial-contains 'gohelp: key s'
vgate_assert 02 serial-contains 'gohelp: browse'
vgate_assert 02 serial-contains 'gohelp: key backspace'
vgate_assert 02 serial-contains 'dui[4]: user user rect=32,32,512,384'
vgate_assert 02 serial-contains 'gohelp: close'
vgate_assert 02 serial-contains 'gohelp OK'
vgate_assert 02 serial-contains 'rx-gohelp-ok'
vgate_assert 02 serial-absent 'gohelp: no /dev/tty'
vgate_assert 02 serial-absent 'gohelp: attach failed'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
