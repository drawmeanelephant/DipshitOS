# live-term.spec -- M45 card SH6 class-B gate (issue #1082, ADR 0020 A).
#
# TERM.BIN (EL0) opens a .user window, opens /dev/tty, attaches the window
# front-end via sys_tty_attach(2, id), and runs the shared shell core. The
# kernel drains the terminal output ring into a bounded grid and renders it
# into the bound window (A4); window keys are encoded by hid_to_bytes into
# the terminal input queue (A5); closing auto-detaches (A6). Boot default is
# unchanged -- the monitor keeps the raw console and TERM.BIN never touches
# it. Markers are emitted in single writes (the SMP heartbeat splits lines).
#
# This gate: exec TERM.BIN, type a bounded ANSI burst over the WM input seam,
# observe the submitted line + exit status on serial, observe the window in
# the dui registry, and decode a raw snapshot for painted SGR cells. M71a is
# landed on this base, so this is the default GOTABWM seat — no `wm=tabwm`
# fallback is requested here.

vgate_name live-term "#1082 SH6 + M72b: TERM.BIN window tty paints SGR cells (default GOTABWM seat)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TERM.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_run 01 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string "printf '\\e[2J\\e[H\\e[31mRED\\e[0m \\e[1;44;97mBOLD\\e[0m\\n\\e[93m\\xE2\\x94\\x8C\\xE2\\x94\\x80\\xE2\\x94\\x90\\xE2\\x94\\x82\\xE2\\x94\\x94\\xE2\\x94\\x98 \\xC3\\xA9 \\xE4\\xBD\\xA0\\e[0m'"$'\n' \
    --input-string-after 'term: attached' \
    --cvc-snap --snapshot-after 'term: done' --snapshot-out '$RUN_DIR/snap' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'term: done' \
    --script-expect 'dui: windows=' \
    --timeout 120

vgate_assert 01 serial-contains 'term: ready'
vgate_assert 01 serial-contains 'term: attached'
vgate_assert 01 serial-contains 'term: line printf'
vgate_assert 01 serial-contains 'term: done status=0'
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

# The TERM window is at (64,48) 640x400; the compositor draws a 16px title
# bar over the top, so the grid's glyphs live in the client area below it.
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
print(f"term client region: fg={fg} bg={bg} red={red} blue_bg={blue_bg} bright={bright}")
assert bg >= 200, f"terminal background not present (bg={bg})"
# `2J` deliberately erases the echoed printf command. At this steady-state
# snapshot only the fresh prompt is terminal-green (observed 40 pixels on VZ),
# so 20 is a twofold safety margin rather than the old pre-clear count.
assert fg >= 20, f"terminal shell glyphs not rendered (fg={fg})"
assert red >= 10, f"ANSI red foreground not painted (red={red})"
assert blue_bg >= 10, f"ANSI blue background not painted (blue_bg={blue_bg})"
assert bright >= 10, f"ANSI bright/bold foreground not painted (bright={bright})"
print("PASS: TERM.BIN window painted the typed ANSI SGR burst on the scanout")

# M73a-2 (#1631): the typed frame row is grid line 1 -> y72..79, cells at
# x = 64 + c*8 (window at 64,48 + 16px title). Bright yellow (\e[93m =
# 0xf5f543): the light frame occupies cols 0..5, the accented e col 7, and
# the wide unmapped rune spans cols 9..10. Nothing may paint past col 10
# (x = 152): that would be a column shift.
def is_yellow(p):
    r, g, b = p
    return r > 180 and g > 180 and b < 120
band = [(x, y) for y in range(72, 80) for x in range(64, 704) if is_yellow(px(x, y))]
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
PY
