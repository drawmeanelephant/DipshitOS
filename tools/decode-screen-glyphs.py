#!/usr/bin/env python3
"""decode-screen-glyphs.py -- decode a captured framebuffer PNG against the
kernel's font8x8.zig glyph table and score FORWARD vs MIRRORED orientation.

The gate tools/verify-live-glyphs.sh is the mirror-regression tripwire: a
captured frame whose text reads FORWARD matches the font table with ~zero
unknown cells, while a mirrored frame explodes with unknowns (the matcher
can tell the difference). This tool is the mechanical part — it finds the
green glyph grid (pitch + origin), decodes the visible session in both
orientations, prints the decoded text (the evidence) and a machine-readable
STATS line for the gate to assert on.

It ALSO decodes the Driving Award clock overlay (the window manager's
amber title bar + "DRIVING AWARD" accent line on navy) in both
orientations, emitting CLOCK_TITLE/CLOCK_BODY lines and clock_* unknown
counts in the STATS line — covering the window-manager path (G5's
draw_string + blit_rect), which shares the forward glyph blit but uses a
different color pair, so a mirror there would NOT trip the green-terminal
matcher.

Calibration (claim-time observations, 2026-08-12): the composited-window
captures (ScreenCaptureKit) render the guest framebuffer with display
smoothing, so each glyph stroke carries a bright core (g ~190-251) inside a
dimmer anti-aliased smear (g ~45-90). The matcher thresholds at the bright
core (g > 140, green-dominant) — at that level the strokes sit at their
exact ideal 2x positions (verified cell-by-cell on the 'D'), while the
smear (g < 90) is excluded. The offscreen cacheDisplay fallback captures
are bright-green throughout and pass the same threshold. A cell matches
its glyph when the Hamming score (bits set in the sampled cell XOR the
font glyph) is small.

Dependency-free by the gate convention (zlib/struct only, like the other
gates' inline PNG decoders).

Usage:
  python3 tools/decode-screen-glyphs.py <capture.png|capture> [--mirror-lines N]

Exit 0 when the grid is found and decoded; 1 when no text grid is present
(blank/garbage frame). The STATS line is always printed; the gate asserts
on it.
"""

import re
import struct
import sys
import zlib

# ---------------------------------------------------------------- font table
def load_font():
    src = open("kernel/src/font8x8.zig").read()
    body = src[src.index("pub const glyphs"):]
    body = body.split("};")[0]
    hexes = re.findall(r"0x([0-9a-fA-F]{2})", body)
    rows = [int(h, 16) for h in hexes]
    n = len(rows) // 8
    return [rows[i * 8:(i + 1) * 8] for i in range(n)]

# ------------------------------------------------------- dependency-free png
def load_png(path):
    # The runner's captures are <base>-Ns with NO extension; accept both.
    if not path.endswith(".png"):
        try:
            d = open(path, "rb").read()
        except OSError:
            d = open(path + ".png", "rb").read()
    else:
        d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8
    idat = b""
    w = h = ct = 0
    while pos < len(d):
        ln, typ = struct.unpack(">I4s", d[pos:pos + 8])
        data = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", data[:10])
        elif typ == b"IDAT":
            idat += data
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp = 4 if ct == 6 else 3
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if f == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xff
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xff
        elif f == 3:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xff
        out += line
        prev = line
    return w, h, bpp, out

# ------------------------------------------------------------------- main
def main():
    path = sys.argv[1]
    mirror_lines = 3
    for i, a in enumerate(sys.argv[2:]):
        if a == "--mirror-lines":
            mirror_lines = int(sys.argv[i + 3])

    font = load_font()
    w, h, bpp, out = load_png(path)

    def px(x, y):
        k = (y * w + x) * bpp
        return out[k], out[k + 1], out[k + 2]

    # Bright green core (see the calibration note above): the anti-aliased
    # smear around each stroke is excluded, the stroke core is kept.
    def is_greenish(r, g, b):
        return g > 140 and g > r * 1.4 and g > b * 1.4

    # Dense green row/col profiles (the terminal text band).
    rowsum = [0] * h
    colsum = [0] * w
    for y in range(h):
        for x in range(0, w, 2):
            if is_greenish(*px(x, y)):
                rowsum[y] += 1
                colsum[x] += 1
    dense = [y for y in range(h) if rowsum[y] > 40]
    if not dense:
        print("STATS fwd_unknowns=-1 fwd_ink=0 mir_unknowns=-1 mir_ink=0 "
              "(no dense green text rows — blank or non-terminal frame)")
        sys.exit(1)
    y1 = max(dense)

    # Grid pitch for 8x8 glyphs: 16 at 2x (the runner's retina window), 8
    # at 1x. Try both; the decode score decides.
    def sample_cell(ox, oy, c, r, pitch):
        cell = []
        for rr in range(8):
            row = 0
            for bb in range(8):
                cx = ox + c * pitch + bb * pitch // 8
                cy = oy + r * pitch + rr * pitch // 8
                if cx < w and cy < h and is_greenish(*px(cx, cy)):
                    row |= 1 << (7 - bb)
            cell.append(row)
        return cell

    ncols = (w - 0) // 16 + 2

    def decode(ox, oy, mirror, pitch):
        nlines = (y1 - oy) // pitch + 2
        lines = []
        for line in range(nlines):
            s = []
            for c in range(ncols):
                cell = sample_cell(ox, oy, c, line, pitch)
                ink = sum(bin(r).count("1") for r in cell)
                if ink == 0:
                    s.append(" ")
                    continue
                best, bestc = 8 * 8 + 1, None
                for idx, g in enumerate(font):
                    sc = 0
                    for r in range(8):
                        a = cell[r]
                        b = (int(format(g[r], "08b")[::-1], 2)
                             if mirror else g[r])
                        sc += bin(a ^ b).count("1")
                    if sc < best:
                        best, bestc = sc, idx
                # Known glyphs are matched with a small score (measured:
                # 0-3 on the banner/session text); the mismatch budget
                # tolerates a stroke pixel here and there. A genuinely
                # wrong cell (mirror-garbage, cursor, partial frame) scores
                # in the tens.
                s.append(chr(0x20 + bestc) if best <= 10 else "?")
            lines.append("".join(s).rstrip())
        return lines

    # 2D phase search over the cell origins (each axis in [0, pitch)) and
    # the pitch candidates. The probe lines (the boot banner's first ~6)
    # must carry real ink — an all-empty origin trivially has zero
    # unknowns and must not win — then minimize unknown cells, tie-broken
    # by more ink.
    def score(ox, oy, pitch):
        lines = decode(ox, oy, False, pitch)
        nq = sum(l.count("?") for l in lines[:6])
        ink = sum(1 for l in lines[:6] for ch in l if ch != " ")
        return nq, ink

    best = None
    for pitch in (16, 8):
        for oy_c in range(pitch):
            for ox_c in range(pitch):
                nq, ink = score(ox_c, oy_c, pitch)
                if ink < 20:
                    continue
                s = (nq, -ink)
                if best is None or s < best[0]:
                    best = (s, ox_c, oy_c, pitch)
    if best is None:
        print("STATS fwd_unknowns=-1 fwd_ink=0 mir_unknowns=-1 mir_ink=0 "
              "(no glyph grid found)")
        sys.exit(1)
    _, ox, oy, pitch = best
    lines_f = decode(ox, oy, False, pitch)
    lines_m = decode(ox, oy, True, pitch)

    def stats(lines):
        ink = unknown = 0
        for l in lines:
            for ch in l:
                if ch == " ":
                    continue
                ink += 1
                if ch == "?":
                    unknown += 1
        return ink, unknown

    fwd_ink, fwd_unknown = stats(lines_f)
    mir_ink, mir_unknown = stats(lines_m)

    # --- the window manager's clock overlay (milestone six G5) -----------
    # The terminal's green text is the original tripwire; the Driving Award
    # clock window (amber title bar + amber "DRIVING AWARD" accent on navy)
    # shares the SAME forward glyph blit but uses a DIFFERENT color pair,
    # so a mirror in the window-manager path (G5's draw_string + blit_rect)
    # would NOT trip the green matcher above. Decode the clock's STATIC
    # strings (title "clock" + body "DRIVING AWARD") in both orientations
    # too, so a flip anywhere fails mechanically.
    def ink_dark(pr, pg, pb):
        return pr + pg + pb < 250  # dark title text on the amber bar

    def ink_amber(pr, pg, pb):
        return pr > pg > pb and pr > 120  # amber accent on navy (hue-specific)

    def decode_clock(ox, oy, nchars, mirror, ink_fn):
        s = []
        for c in range(nchars):
            cell = []
            for rr in range(8):
                row = 0
                for bb in range(8):
                    cx = ox + c * pitch + bb * pitch // 8
                    cy = oy + rr * pitch // 8
                    if cx < w and cy < h:
                        pr, pg, pb = px(cx, cy)
                        if ink_fn(pr, pg, pb):
                            row |= 1 << (7 - bb)
                cell.append(row)
            ink = sum(bin(rw).count("1") for rw in cell)
            if ink == 0:
                s.append(" ")
                continue
            best_sc, best_c = 8 * 8 + 1, None
            for idx, g in enumerate(font):
                sc = 0
                for ri in range(8):
                    a = cell[ri]
                    b = (int(format(g[ri], "08b")[::-1], 2) if mirror else g[ri])
                    sc += bin(a ^ b).count("1")
                if sc < best_sc:
                    best_sc, best_c = sc, idx
            s.append(chr(0x20 + best_c) if best_sc <= 10 else "?")
        return "".join(s)

    # The clock window is at fixed framebuffer coordinates (960,16,304x192);
    # the title text sits at (968,22) and the body line at (968,42). The
    # capture scale follows the terminal's detected pitch (16 = 2x retina,
    # 8 = 1x).
    cscale = pitch // 8
    clock_title = decode_clock(968 * cscale, 22 * cscale, 5, False, ink_dark)
    clock_title_m = decode_clock(968 * cscale, 22 * cscale, 5, True, ink_dark)
    clock_body = decode_clock(968 * cscale, 42 * cscale, 13, False, ink_amber)
    clock_body_m = decode_clock(968 * cscale, 42 * cscale, 13, True, ink_amber)

    def unknowns(s):
        return sum(1 for ch in s if ch == "?")

    ct_fwd_u = unknowns(clock_title)
    ct_mir_u = unknowns(clock_title_m)
    cb_fwd_u = unknowns(clock_body)
    cb_mir_u = unknowns(clock_body_m)

    print("glyph grid: pitch=%d origin=(%d,%d)" % (pitch, ox, oy))
    print("--- decoded session (forward) ---")
    for l in lines_f:
        if l.strip():
            print(l[:160])
    print("--- top lines mirrored (demo) ---")
    for l in lines_m[:mirror_lines]:
        if l.strip():
            print(l[:160])
    print("--- decoded clock window (forward) ---")
    print("CLOCK_TITLE=%s" % clock_title)
    print("CLOCK_BODY=%s" % clock_body)
    print("--- decoded clock window (mirrored) ---")
    print("CLOCK_TITLE_MIR=%s" % clock_title_m)
    print("CLOCK_BODY_MIR=%s" % clock_body_m)
    print("STATS fwd_unknowns=%d fwd_ink=%d mir_unknowns=%d mir_ink=%d "
          "clock_title_fwd_u=%d clock_title_mir_u=%d "
          "clock_body_fwd_u=%d clock_body_mir_u=%d"
          % (fwd_unknown, fwd_ink, mir_unknown, mir_ink,
             ct_fwd_u, ct_mir_u, cb_fwd_u, cb_mir_u))

if __name__ == "__main__":
    main()
