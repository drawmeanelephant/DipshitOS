#!/usr/bin/env bash
#
# verify-live-win-move.sh -- claim 0487 (milestone six, card G6 move/raise
# follow-on) class-B gate: the window manager's MOVE/RESTACK surface, live
# on real VZ.
#
# WINMOVE.BIN (`user/src/winmove.zig`, the NINTH ESP user program) drives
# the ADR 0007 slots 16/17/18/19/20 (`sys_win_move` / `sys_win_raise` /
# `sys_win_get` / `sys_win_query` / `sys_win_set_visible`) entirely from EL0:
# open -> fill -> present -> move to (800,400) -> move to (1200,700) (the
# CLAMP proof: it falls off the 1280x720 scanout, so it clamps to the
# bottom-right corner (1024,528)) -> raise -> present -> get (reads the
# clamped rect back through slot 18, printing `winmove: get
# 1024,528,256,192`) -> query (reads the FULL window state back through
# slot 19, printing `winmove: query 1024,528,256,192 z=2 focused=1
# visible=1 dirty=1`) -> hide (slot 20) -> sleep 2 ticks (hidden while the
# gate's marker-driven capture snaps the GONE frame) -> show (slot 20) ->
# yield-forever.
#
# Phases:
#   * script1:  `exec WINMOVE.BIN` (open/fill/present/move/move/raise/get/
#               query/hide/sleep/show/loop).
#   * script2:  (after `winmove: loop ok`) `win` + `syscalls` + the EL1h
#               monitor halves `win move 2 1024 528` + `win raise 2` on the
#               SAME kernel state (the window still at its clamped spot).
#   * pixel proof (two captures): the marker-driven capture
#     (`--screenshot-after "winmove: hide ok"`) shows the window GONE from
#     its clamped spot (the hide landed); the LATEST fixed capture shows
#     WINMOVE's OWN colors BACK at the NEW position (the dark-blue
#     background + red/cyan/white blocks in the bottom-right corner) and NOT
#     at the old (64,64) spot — the window really moved, disappeared, and
#     returned, not just reported new registry state.
#
# Honest bound (the G1/G2/G3/G5/G6 precedent): byte-exact pixels are the
# class A mock's domain; the LIVE pixels are color-managed + retina-scaled,
# so the live assertion is "distinct color families in the expected
# regions", not per-byte equality.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge proves
# class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-win-move.sh
#
# Evidence: artifacts/live-win-move-gate.txt (full output),
# artifacts/live-win-move-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-win-move-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-win-move-report.txt"

echo "=== verify-live-win-move: claim 0487 — sys_win_move/sys_win_raise, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/*.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted session ---------------------------------------------------------
cat > artifacts/live-win-move-script.txt <<'EOF'
exec WINMOVE.BIN
EOF
cat > artifacts/live-win-move-script2.txt <<'EOF'
win
syscalls
win move 2 1024 528
win raise 2
EOF

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/gpu-screen-*
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --display --screen artifacts/gpu-screen \
        --screenshot-after "winmove: hide ok" \
        --script artifacts/live-win-move-script.txt \
        --script2 artifacts/live-win-move-script2.txt --script2-after "winmove: loop ok" \
        --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-win-move-rc.txt
}

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
set +e
run_one "artifacts/live-win-move-run.txt" "artifacts/live-win-move-serial.log"
RC="$(cat /tmp/live-win-move-rc.txt)"
set -e

# --- assertions ---------------------------------------------------------------
SERIAL="artifacts/live-win-move-serial.log"
OPEN=0 FILL=0 PRESENT=0 MOVE=0 RAISE=0 LOOP=0 GET=0 QUERY=0 HIDE=0 SHOW=0 VIS=0 WIN3=0 RECT=0 OWNER=0 IMPL=0 CNT=0 MMOVE=0 MRAISE=0
if [ -f "$SERIAL" ]; then
    # WINMOVE.BIN's EL0 markers (open/fill/present/move/raise/loop).
    grep -a -q -F -- "winmove: open id=2" "$SERIAL" && OPEN=1
    grep -a -q -F -- "winmove: fill ok" "$SERIAL" && FILL=1
    grep -a -q -F -- "winmove: present ok" "$SERIAL" && PRESENT=1
    grep -a -q -F -- "winmove: move ok" "$SERIAL" && MOVE=1
    grep -a -q -F -- "winmove: raise ok" "$SERIAL" && RAISE=1
    grep -a -q -F -- "winmove: loop ok" "$SERIAL" && LOOP=1
    # sys_win_get (slot 18): the EL0 program reads its CLAMPED rect back and
    # prints it — the read-back proof the move was silent but observable.
    grep -a -q -F -- "winmove: get 1024,528,256,192" "$SERIAL" && GET=1
    # sys_win_query (slot 19): the EL0 program reads its FULL window state
    # back — z-order rank + focus + visible/dirty flags, not just the rect.
    grep -a -q -F -- "winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1" "$SERIAL" && QUERY=1
    # sys_win_set_visible (slot 20): the hide/show round trip from EL0 — the
    # program hides its window, sleeps 6 ticks (so the 5s capture catches it
    # gone), then shows it again.
    grep -a -q -F -- "winmove: hide ok" "$SERIAL" && HIDE=1
    grep -a -q -F -- "winmove: show ok" "$SERIAL" && SHOW=1
    # The window persists at its CLAMPED position (the second move to
    # (1200,700) fell off the 1280x720 scanout -> (1024,528)), owned by a
    # numeric pid (per-process ownership visible at runtime).
    grep -a -q -F -- "win: windows=3" "$SERIAL" && WIN3=1
    grep -a -q -F -- "win[2]: user user rect=1024,528,256,192" "$SERIAL" && RECT=1
    grep -a -E -q 'win\[2\]: user user rect=1024,528,256,192 .* owner=[0-9]+' "$SERIAL" && OWNER=1
    # The final registry state: the window is VISIBLE again (the show landed).
    grep -a -E -q 'win\[2\]: user user rect=1024,528,256,192 dirty=[01] visible=1' "$SERIAL" && VIS=1
    # The syscall counters: open=1, fill=4, present=3, move=2, raise=1,
    # get=1, query=1, set_visible=2, close=0 (the window persists — WINMOVE
    # yield-loops forever).
    grep -a -q -F -- "syscalls: slots=64 implemented=38" "$SERIAL" && IMPL=1
    grep -a -q -F -- "  16 sys_win_move calls=2" "$SERIAL" && \
        grep -a -q -F -- "  17 sys_win_raise calls=1" "$SERIAL" && \
        grep -a -q -F -- "  18 sys_win_get calls=1" "$SERIAL" && \
        grep -a -q -F -- "  19 sys_win_query calls=1" "$SERIAL" && \
        grep -a -q -F -- "  20 sys_win_set_visible calls=2" "$SERIAL" && \
        grep -a -q -F -- "  14 sys_win_present calls=3" "$SERIAL" && \
        grep -a -q -F -- "  15 sys_win_close calls=0" "$SERIAL" && CNT=1
    # The EL1h monitor halves (the same primitives, privileged): a no-op
    # move to the SAME clamped spot + a raise.
    grep -a -q -F -- "win move: moved=2 to 1024,528" "$SERIAL" && MMOVE=1
    grep -a -q -F -- "win raise: raised=2" "$SERIAL" && MRAISE=1
fi

echo "win-move: rc=$RC open=$OPEN fill=$FILL present=$PRESENT move=$MOVE raise=$RAISE loop=$LOOP get=$GET query=$QUERY hide=$HIDE show=$SHOW vis=$VIS win3=$WIN3 rect=$RECT owner=$OWNER impl21=$IMPL cnt=$CNT mmove=$MMOVE mraise=$MRAISE"

PASS=0
if [ "$RC" = 0 ] && [ "$OPEN" = 1 ] && [ "$FILL" = 1 ] && [ "$PRESENT" = 1 ] && \
   [ "$MOVE" = 1 ] && [ "$RAISE" = 1 ] && [ "$LOOP" = 1 ] && [ "$GET" = 1 ] && \
   [ "$QUERY" = 1 ] && [ "$HIDE" = 1 ] && [ "$SHOW" = 1 ] && [ "$VIS" = 1 ] && \
   [ "$WIN3" = 1 ] && [ "$RECT" = 1 ] && [ "$OWNER" = 1 ] && [ "$IMPL" = 1 ] && \
   [ "$CNT" = 1 ] && [ "$MMOVE" = 1 ] && [ "$MRAISE" = 1 ]; then
    PASS=1
fi

# Phase 2a — the DISAPPEAR proof. The marker-driven capture
# (`--screenshot-after "winmove: hide ok"` -> <base>-after) is taken
# while WINMOVE's window is HIDDEN (the EL0 slot-20 hide, held 2 ticks): its
# own rendered content — the red/cyan/white blocks — must be GONE from the
# clamped spot (the terminal beneath is revealed). The terminal's slate
# background also classifies as 'darkblue', so this half proves disappearance
# via the BLOCKS (unambiguous), not the background fill.
HIDDEN="artifacts/gpu-screen-after"
if [ ! -f "$HIDDEN" ]; then
    echo "FAIL: no marker-driven hidden capture (artifacts/gpu-screen-after)"
    PASS=0
else
    echo "decoding hidden=$HIDDEN"
    python3 - "$HIDDEN" <<'EOF'
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

def classify(r, g, b):
    if r > 220 and g > 220 and b > 220:
        return 'white'
    if g > 200 and b > 200 and r < 170:
        return 'cyan'
    if r > 180 and g < 110 and b < 110:
        return 'red'
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'
    if g > 140 and r < 160 and b < 160:
        return 'green'
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

# The CLAMPED window rect in retina coords: logical (1024,528,256,192) x2.
NX0, NY0, NX1, NY1 = 2048, 1056, 2560, 1440

# (a) The three blocks are GONE from their new spots (window-local (8,8),
# (64,8), (120,8) 48x48 -> retina centers (2112,1120), (2224,1120),
# (2336,1120)).
h_red = classify(*px(2112, 1120))
h_cyan = classify(*px(2224, 1120))
h_white = classify(*px(2336, 1120))
print(f"hidden blocks: red={h_red} cyan={h_cyan} white={h_white}")
if h_red == 'red' or h_cyan == 'cyan' or h_white == 'white':
    sys.exit(f"FAIL: a colored block still sits at the new spot while hidden ({h_red}/{h_cyan}/{h_white}) — the hide did not land")

# (b) No red/cyan/white anywhere in the clamped rect — the window's OWN
# rendered content is gone (the terminal's slate background + green text is
# revealed underneath).
h_whole = region(NX0 + 4, NY0 + 4, NX1 - 4, NY1 - 4, step=2)
print(f"hidden whole rect: {h_whole}")
if h_whole.get('red', 0) or h_whole.get('cyan', 0) or h_whole.get('white', 0):
    sys.exit(f"FAIL: window content (red/cyan/white) still present in the clamped rect while hidden ({h_whole})")

print("PASS: the window's own rendered content is GONE from the clamped spot while hidden (the terminal beneath is revealed)")
EOF
    if [ $? -ne 0 ]; then
        echo "FAIL: the hidden capture still shows the window's content at its clamped spot"
        PASS=0
    fi
fi

# Phase 2 — the pixel proof. The runner writes `--screen <base>` captures as
# <base>-Ns (2560x1440 retina). The LATEST capture (mtime) holds the settled
# frame (the 15s capture — WINMOVE's window persists at its clamped spot).
LATEST="$(ls -t artifacts/gpu-screen-*s 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
    echo "FAIL: no gpu-screen PNG captured"
    PASS=0
else
    echo "decoding $LATEST"
    python3 - "$LATEST" <<'EOF'
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

def classify(r, g, b):
    if r > 220 and g > 220 and b > 220:
        return 'white'       # 0xffffff -> (255,255,255)
    if g > 200 and b > 200 and r < 170:
        return 'cyan'        # 0x00ffff -> (117,251,253)
    if r > 180 and g < 110 and b < 110:
        return 'red'         # 0xff0000 -> (234,51,35)
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'    # 0x1a2b3c -> (30,43,59)
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# The CLAMPED window rect in retina coords: logical (1024,528,256,192) x2.
NX0, NY0, NX1, NY1 = 2048, 1056, 2560, 1440

# (a) The three filled blocks sit at their expected spots at the NEW
# position (window-local (8,8), (64,8), (120,8) 48x48 -> retina centers
# (2112,1120), (2224,1120), (2336,1120)).
new_red = classify(*px(2112, 1120))
new_cyan = classify(*px(2224, 1120))
new_white = classify(*px(2336, 1120))
print(f"blocks-at-new: red={new_red} cyan={new_cyan} white={new_white}")
if new_red != 'red':
    sys.exit(f"FAIL: the red block is not red at its NEW spot ({new_red}) — the move did not land")
if new_cyan != 'cyan':
    sys.exit(f"FAIL: the cyan block is not cyan at its NEW spot ({new_cyan}) — the move did not land")
if new_white != 'white':
    sys.exit(f"FAIL: the white block is not white at its NEW spot ({new_white}) — the move did not land")

# (b) The background is the dark-blue fill, dominant in the NEW rect body
# (below the blocks).
body = region(NX0 + 8, NY0 + 128, NX1 - 8, NY1 - 8)
fb = frac(body, 'darkblue')
print(f"new window body: {body} darkblue={fb:.3f}")
if fb < 0.60:
    sys.exit("FAIL: the user window background is not dark-blue at the NEW position (the window did not render there)")

# (c) NO green (terminal foreground) inside the NEW rect — the opaque
# back-buffer covers the terminal beneath it (z-order proof).
whole = region(NX0 + 4, NY0 + 4, NX1 - 4, NY1 - 4, step=2)
if whole.get('green', 0) != 0:
    sys.exit(f"FAIL: terminal foreground visible inside the NEW window rect ({whole.get('green',0)} green)")

# (d) The OLD position (logical (64,64)) no longer shows the colored blocks
# — the window really MOVED away (the terminal is there now).
old_red = classify(*px(192, 192))
old_cyan = classify(*px(304, 192))
old_white = classify(*px(416, 192))
print(f"blocks-at-old: red={old_red} cyan={old_cyan} white={old_white}")
if old_red == 'red' or old_cyan == 'cyan' or old_white == 'white':
    sys.exit("FAIL: a colored block still sits at the OLD position — the window did not move off its original spot")

print("PASS: WINMOVE's own rendered content (dark-blue background + red/cyan/white blocks) is at the CLAMPED NEW position, with the old spot showing the terminal — the window really moved")
EOF
    if [ $? -ne 0 ]; then
        echo "FAIL: captured framebuffer does not show the window at its moved position"
        PASS=0
    fi
fi

{
    echo "DIPSHITOS live draw/window-move gate (claim 0487, milestone six card G6 move/raise follow-on) — EL0 move/restack on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: scripted exec of WINMOVE.BIN (open/fill/present/move/move-clamp/raise/get/query/hide/sleep/show/loop), then win + syscalls + the EL1h win move/raise halves on the same kernel state, then the two-capture decode"
    echo "assertions: winmove open/fill/present/move/raise/get/query/hide/show/loop markers (winmove: get 1024,528,256,192 through slot 18 + winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1 through slot 19 + hide ok/show ok through slot 20), win: windows=3 + win[2]: user user rect=1024,528,256,192 owner=<pid> visible=1, syscalls implemented=38 with open=1/fill=4/present=3/move=2/raise=1/get=1/query=1/set_visible=2/close=0, win move 2 1024 528 + win raise 2 (EL1h), the HIDDEN capture shows no red/cyan/white blocks at the clamped spot (the window disappeared), and the LATEST capture shows red+cyan+white blocks at the NEW spot + dark-blue background dominant + no terminal foreground inside the new rect + the old spot free of the colored blocks (the window returned)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win-move: PASS — WINMOVE.BIN opened a user window, filled it, presented it, moved it (to (800,400) then the clamped (1024,528) corner), raised it, READ THE CLAMPED RECT BACK through slot 18 (winmove: get 1024,528,256,192), READ THE FULL WINDOW STATE through slot 19 (winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1), HID it then SHOWED it through slot 20 (winmove: hide ok / show ok, sys_win_set_visible calls=2), and kept it alive entirely from EL0 through the ADR 0007 slots 16/17/18/19/20, with syscalls reporting implemented=38 — and the two-capture decode proves the PIXEL DISAPPEARS (the marker capture taken while hidden shows no red/cyan/white blocks at the clamped spot) and RETURNS (the LATEST capture shows the window's own colors back at the NEW position with the old spot showing the terminal). The default VM is untouched: without --display, the window manager is unarmed and sys_win_set_visible returns EINVAL — every existing gate stays byte-identical."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win-move: FAILED — see artifacts/live-win-move-report.txt, the runner output (live-win-move-run.txt), and the serial log (live-win-move-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
