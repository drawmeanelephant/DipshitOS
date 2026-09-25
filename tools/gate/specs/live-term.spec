# live-term.spec -- M45 card SH6 class-B gate (issue #1082, ADR 0020 A),
# retargeted by M73d (#1628) onto GOTERM.ELF — the canonical terminal; the
# Zig TERM.BIN front-end retires into M60's leftovers (docs/status.md row 60).
#
# GOTERM.ELF (EL0, tabapp client) opens a .user window, opens /dev/tty,
# attaches the window front-end via sys_tty_attach(2, id), and runs the
# shared shlib core (M73c #1627). The seam this gate proves is unchanged:
# the kernel drains the terminal output ring into a bounded grid and renders
# it into the bound window (A4); window keys are encoded by hid_to_bytes into
# the terminal input queue (A5); closing auto-detaches (A6). Boot default is
# unchanged -- the monitor keeps the raw console and GOTERM never touches
# it. Markers are emitted in single writes (the SMP heartbeat splits lines).
# GOTERM says `goterm:` where TERM.BIN said `term:`; every assertion below
# moved by prefix alone (the M66c/NOTE precedent) — none dropped: the SGR
# thresholds, the M73a-2 frame-rune proofs, and the M73h exact-RGB
# truecolour proofs keep their ORIGINAL coordinates, because GOTERM declares
# the classic terminal rect 64,48,640,400 — the rect TERM.BIN declared.
#
# The rect is load-bearing, not cosmetic (observed 2026-09-22, M73d):
# 640px = 80 grid columns = the kernel grid's default, so syncWindowCols
# never reflows (Screen.reflow early-outs when cols is unchanged). A 512px
# window forced an 80->64 reflow of live history and the window kept
# painting PRE-clear rows while the grid itself held the fresh content —
# the typed burst never reached the scanout. Retired TERM.BIN (always
# 640) never reflowed; every 512px tabapp client did (GOSH and GOTERM both
# went stale, control stayed green — the four-cell A/B).
#
# COMPOSITOR REGIME: this gate boots WITHOUT GOTABWM.ELF on the share, so
# `wm: autostart` falls back to shim compositing and GOTERM's kind-8
# declare is refused (asserted below; the plain .user window paints — the
# pre-retirement gate ran this same regime: the old header's "default
# GOTABWM seat" claim was aspirational, it never staged the binary).
# Capture is the M69b settle recipe (go-dogfood run 03): a monitor echo
# 4s after `goterm: done` releases --cvc-snap (a fresh guest capture), so
# the frame holds settled output instead of the boot frame.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goterm.sh   ->  .build/go/GOTERM.ELF
#
# M80f (#1723) run 03: DSR query through the real window tty. The reply is
# synthesized by the kernel and enters the same bounded input FIFO as keys;
# the next shell read and completion marker prove it cannot wedge the session.
# The class-A corpus pins the exact reply bytes and queue ordering.
#
# M73m (#1662) run 02 — the palette the USER chose, live: same boot shape,
# but after `goterm: done` has painted the DEFAULT (dark) grid, the monitor
# writes a NON-default palette through the REAL store (`settings set theme
# custom` + palette_fg/bg/accent) and `dui focus` composites. The very next
# frame must show the chosen colours on cells that were painted BEFORE the
# write — no reboot, no re-exec — at exact RGB (0x20ff9e on 0x0b1020), while
# the 38;2/48;2 truecolour pair keeps its exact app-driven RGB (Amendment E
# semantics: a palette never restyles an app's colours) and the old dark
# default green is gone from the client area. Run 01 is untouched and stays
# the dark-theme byte-parity evidence.

vgate_name live-term "#1082 SH6 + M72b + M73d #1628: GOTERM window tty paints SGR cells (classic rect, shim compositing)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOTERM.ELF
EOF

vgate_file script2.txt <<'EOF'
echo shot-term-pixels
dui
EOF

vgate_file script3.txt <<'EOF'
echo rx-live-term-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOTERM.ELF", "build-goterm.sh"),):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" % (name, os.path.getsize(src)))
# Deliberately NOT staged: GOTABWM.ELF — this gate boots the shim
# compositing regime (the header's evidence note); staging the seat would
# move the window to full-viewport and change every pixel band below.
PY

vgate_run 01 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string "printf '\\e[2J\\e[H\\e[31mRED\\e[0m \\e[1;44;97mBOLD\\e[0m\\n\\e[93m\\xE2\\x94\\x8C\\xE2\\x94\\x80\\xE2\\x94\\x90\\xE2\\x94\\x82\\xE2\\x94\\x94\\xE2\\x94\\x98 \\xC3\\xA9 \\xE4\\xBD\\xA0\\e[0m\\n\\e[38;2;255;128;71;48;2;17;34;51mTC\\e[0m'"$'\n' \
    --input-string-after 'goterm: attached' \
    --cvc-snap --snapshot-after 'shot-term-pixels' --snapshot-out '$RUN_DIR/snap' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'goterm: done' --script2-delay 4 \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'shot-term-pixels' \
    --script-expect 'rx-live-term-ok' \
    --timeout 150

vgate_assert 01 serial-contains 'goterm: ready'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'goterm: declare refused'
vgate_assert 01 serial-contains 'goterm: line printf'
vgate_assert 01 serial-contains 'goterm: done status=0'
vgate_assert 01 serial-contains 'user user rect=64,48,640,400'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 snapshot 'snap-*.raw' <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return data[k+2], data[k+1], data[k]  # R, G, B

# The GOTERM window is at (64,48) 640x400 — the classic terminal rect; the
# compositor draws a 16px title bar over the top, so the grid's glyphs live
# in the client area below it.
fg = 0
bg = 0
red = 0
blue_bg = 0
bright = 0
for y in range(66, 446, 2):
    for x in range(66, 702, 2):
        r, g, b = px(x, y)
        if g > 140 and r < 160 and b < 160:
            fg += 1
        elif max(r, g, b) < 40:
            bg += 1
        if r > 150 and g < 100 and b < 100:
            red += 1
        if b > 130 and g > 60 and g < 150 and r < 100:
            blue_bg += 1
        if r > 220 and g > 220 and b > 220:
            bright += 1
# M73l (#1661): RED and BOLD sit on line 0 (y64..79 — client origin64
# + one cell_h of 16). Their ink is antialiased now: only the top nibble
# levels clear the exact-colour predicates (observed at the region stride:
# red=3, bright=4 — sized for the retired 1-bit ink), so probe line 0 at
# full resolution; the region loop above keeps fg/bg/blue_bg as before.
for y in range(64, 80):
    for x in range(64, 704):
        r, g, b = px(x, y)
        if r > 150 and g < 100 and b < 100: red += 1
        if r > 220 and g > 220 and b > 220: bright += 1
print(f"term client region: fg={fg} bg={bg} red={red} blue_bg={blue_bg} bright={bright}")
assert bg >= 200, f"terminal background not present (bg={bg})"
# `2J` deliberately erases the echoed printf command. At this steady-state
# snapshot only the fresh prompt is terminal-green (observed 40 pixels on VZ),
# so 20 is a twofold safety margin rather than the old pre-clear count.
assert fg >= 20, f"terminal shell glyphs not rendered (fg={fg})"
assert red >= 10, f"ANSI red foreground not painted (red={red})"
assert blue_bg >= 10, f"ANSI blue background not painted (blue_bg={blue_bg})"
assert bright >= 10, f"ANSI bright/bold foreground not painted (bright={bright})"
print("PASS: GOTERM window painted the typed ANSI SGR burst on the scanout")

# M73a-2 (#1631): the typed frame row is grid line 1 -> y80..95 (M73l
# #1661: cell_h=16 — client origin 64 + 1 line), cells at
# x = 64 + c*8 (window at 64,48 + 16px title). Bright yellow (\e[93m =
# 0xf5f543): the light frame occupies cols 0..5, the accented e col 7, and
# the wide unmapped rune spans cols 9..10. Nothing may paint past col 10
# (x = 152): that would be a column shift.
def is_yellow(p):
    r, g, b = p
    return r > 180 and g > 180 and b < 120
band = [(x, y) for y in range(80, 96) for x in range(64, 704) if is_yellow(px(x, y))]
yellow = len(band)
border = sum(1 for x, y in band if x < 64 + 6 * 8)
accent = sum(1 for x, y in band if 64 + 7 * 8 <= x < 64 + 8 * 8)
wide = sum(1 for x, y in band if 64 + 9 * 8 <= x < 64 + 11 * 8)
past = sum(1 for x, y in band if x >= 64 + 11 * 8)
print(f"frame row: yellow={yellow} border={border} accent={accent} wide={wide} past={past}")
assert yellow >= 40, f"frame runes not painted (yellow={yellow})"
assert border >= 10, f"box-drawing frame not painted (border={border})"
assert accent >= 3, f"accented rune not painted (accent={accent})"
assert wide >= 6, f"wide rune did not span its pair (wide={wide})"
assert past == 0, f"pixels past the content cells: column shift (past={past})"
print("PASS: frame runes, accented rune, and the wide pair painted with no column shift")

# M73h (#1634): line 2 carries one truecolour pair — fg exactly
# (255,128,71) on bg exactly (17,34,51), straight from the SGR side
# arrays through the rendition resolver (ADR 0020 Amendment E). Cell 0..1
# spans x 64..79; the prompt and cursor sit at x >= 80 (outside the scan).
# M73l (#1661): line 2 sits at y96..111 (client 64 + 2 * cell_h 16).
fg_exact = 0
bg_exact = 0
for y in range(96, 112):
    for x in range(64, 80):
        c = px(x, y)
        if c == (255, 128, 71): fg_exact += 1
        if c == (17, 34, 51): bg_exact += 1
print(f"truecolour row: fg_exact={fg_exact} bg_exact={bg_exact}")
assert fg_exact >= 4, f"38;2 cell not painted at exact RGB (fg_exact={fg_exact})"
assert bg_exact >= 40, f"48;2 cell background not painted at exact RGB (bg_exact={bg_exact})"
print("PASS: truecolour fg and bg painted at their exact RGB")
PY

# --- M73m (#1662) run 02: the user's palette, applied LIVE ------------------
# Same boot shape as run 01 (classic rect, shim compositing, one exec). The
# burst paints the DEFAULT (dark) grid first; only after `goterm: done` does
# the monitor write a non-default palette through the REAL store, and the
# `dui focus` line below composites — the snapshot therefore reads cells that
# were painted BEFORE the write, recoloured by it. The share assertions lift
# the SETTINGS.TXT that chose it.
vgate_file script2-palette.txt <<'EOF'
settings set theme custom
settings set palette_fg 20ff9e
settings set palette_bg 0b1020
settings set palette_accent ff7733
dui focus 0
dui
echo shot-palette
EOF

vgate_file script3-palette.txt <<'EOF'
echo rx-live-palette-ok
EOF

vgate_run 02 -- --display --input --via-virtio --screen '$RUN_DIR/screen-palette' \
    --script '$RUN_DIR/script.txt' \
    --input-string "printf '\\e[2J\\e[HDEFAULTINK \\e[38;2;255;128;71;48;2;17;34;51mTC\\e[0m\\n'"$'\n' \
    --input-string-after 'goterm: attached' \
    --script2 '$RUN_DIR/script2-palette.txt' \
    --script2-after 'goterm: done' --script2-delay 4 \
    --script3 '$RUN_DIR/script3-palette.txt' \
    --script3-after 'shot-palette' --script3-delay 4 \
    --cvc-snap --snapshot-after 'shot-palette' --snapshot-out '$RUN_DIR/palette' \
    --script-expect 'rx-live-palette-ok' \
    --timeout 150

vgate_file script3-dsr.txt <<'EOF'
echo rx-live-dsr-ok
EOF

vgate_run 03 -- --display --input --via-virtio --screen '$RUN_DIR/screen-dsr' \
    --script '$RUN_DIR/script.txt' \
    --input-string "printf '\\e[6n'"$'\n' \
    --input-string-after 'goterm: attached' \
    --script2 '$RUN_DIR/script3-dsr.txt' \
    --script2-after 'goterm: done status=0' --script2-delay 1 \
    --script-expect 'rx-live-dsr-ok' --timeout 150

vgate_assert 03 serial-contains 'goterm: attached'
vgate_assert 03 serial-contains 'goterm: line printf'
vgate_assert 03 serial-contains 'goterm: done status=0'
vgate_assert 03 serial-absent '\[EXC\]'
vgate_assert 03 serial-absent '[EXC] parking:'

# M80h (#1724): F5 travels through the real XHCI/custom-virtio input path
# into the bound GOTERM tty. The monitor report runs after the injected key
# and pins both the HID usage and the xterm final byte; class-A encoder tests
# pin the complete F1-F12/Insert vocabulary.
vgate_file script3-fkey.txt <<'EOF'
input
echo rx-live-fkey-ok
EOF

vgate_run 04 -- --display --input --screen '$RUN_DIR/screen-fkey' \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'f5' \
    --input-chords-after 'goterm: attached' \
    --script3 '$RUN_DIR/script3-fkey.txt' \
    --script3-after 'goterm: prompt' --script3-delay 10 \
    --script-expect 'rx-live-fkey-ok' \
    --timeout 60

vgate_assert 04 serial-contains 'kb-usage=0x3f'
vgate_assert 04 serial-contains 'kb-byte=~'

vgate_assert 02 serial-contains 'goterm: ready'
vgate_assert 02 serial-contains 'goterm: attached'
vgate_assert 02 serial-contains 'goterm: done status=0'
# The write went through the real store AND persisted to the share.
vgate_assert 02 serial-contains 'settings: theme=custom (persisted)'
vgate_assert 02 serial-contains 'settings: palette_fg=20ff9e (persisted)'
vgate_assert 02 serial-contains 'settings: palette_bg=0b1020 (persisted)'
vgate_assert 02 serial-contains 'settings: palette_accent=ff7733 (persisted)'
# The repaint trigger: focus the console terminal (window id 0 — this boot's
# registry has no clock, observed 2026-09-23) forces mark+composite, and the
# registry dump that follows shows the windows still dirty from the write.
vgate_assert 02 serial-contains 'dui focus: focused=0'
vgate_assert 02 serial-contains 'user user rect=64,48,640,400'
vgate_assert 02 serial-absent '\[EXC\]'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 share-contains SETTINGS.TXT 'theme=custom'

# Ordering is the live-apply claim: grid painted -> palette written ->
# composited -> snapshot. A write that raced ahead of the paint would put
# the custom colours on a first frame and prove nothing about LIVE apply.
vgate_assert 02 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_done = ser.find("goterm: done status=0")
i_write = ser.find("settings: theme=custom")
i_paint = ser.find("dui focus: focused=0")
i_shot = ser.find("shot-palette")
assert min(i_done, i_write, i_paint, i_shot) >= 0, \
    f"missing marker(s): done={i_done} write={i_write} paint={i_paint} shot={i_shot}"
assert i_done < i_write, f"palette written before the grid painted (done={i_done} write={i_write})"
assert i_write < i_paint, f"composite before the write (write={i_write} paint={i_paint})"
assert i_paint < i_shot, f"snapshot marker before the repaint (paint={i_paint} shot={i_shot})"
print("ordering OK: painted < palette written < composited < snapshot")
PY

vgate_assert 02 snapshot 'palette-*.raw' <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return data[k+2], data[k+1], data[k]  # R, G, B

CUSTOM_FG = (32, 255, 158)   # 0x20ff9e — palette_fg, chosen through the store
CUSTOM_BG = (11, 16, 32)     # 0x0b1020 — palette_bg
OLD_FG = (0, 255, 0)         # 0x00ff00 — the dark default that must be GONE
TC_FG = (255, 128, 71)       # 38;2 cell — app-driven, palette must not touch it
TC_BG = (17, 34, 51)         # 48;2 cell background

# GOTERM window (64,48) 640x400, 16px title bar -> client area x64..703, y64..445.
fg_exact = bg_exact = old_fg = tc_fg = tc_bg = 0
for y in range(64, 446):
    for x in range(64, 704):
        c = px(x, y)
        if c == CUSTOM_FG:
            fg_exact += 1
        elif c == CUSTOM_BG:
            bg_exact += 1
        elif c == OLD_FG:
            old_fg += 1
        if c == TC_FG:
            tc_fg += 1
        if c == TC_BG:
            tc_bg += 1
print(f"palette row: fg_exact={fg_exact} bg_exact={bg_exact} old_fg={old_fg} "
      f"tc_fg={tc_fg} tc_bg={tc_bg}")
assert fg_exact >= 30, f"default-slot ink not at the chosen fg RGB (fg_exact={fg_exact})"
assert bg_exact >= 1000, f"erased grid not at the chosen bg RGB (bg_exact={bg_exact})"
assert old_fg == 0, f"the dark default green is still painted (old_fg={old_fg})"
assert tc_fg >= 4, f"truecolour fg lost its exact RGB (tc_fg={tc_fg})"
assert tc_bg >= 40, f"truecolour bg lost its exact RGB (tc_bg={tc_bg})"
print("PASS: chosen palette painted live, truecolour untouched, old default gone")
PY
