#!/usr/bin/env python3
"""decode-screen-glyphs.py -- decode a captured framebuffer PNG against the
kernel's font8x8.zig glyph table and score FORWARD vs MIRRORED orientation.

The gate tools/verify-live-glyphs.sh is the mirror-regression tripwire: a
captured frame whose text reads FORWARD matches the font table with ~zero
unknown cells, while a mirrored frame explodes with unknowns (the matcher
can tell the difference). The source table is LSB-first (bit 0 is the
leftmost pixel), while sampled screen rows use bit 7 for the leftmost
pixel; the decoder normalizes that boundary explicitly before matching.
This tool is the mechanical part — it finds the green glyph grid (pitch +
origin), decodes the visible session in both orientations, prints the
decoded text (the evidence) and a machine-readable STATS line for the gate
to assert on.

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
  python3 tools/decode-screen-glyphs.py --self-test

The `--self-test` mode is the offline in-cell mirror simulation (class A —
no capture, no VZ boot): it renders the clock window forward with the
kernel's own glyph blit, decodes it, mirrors each glyph in-cell, and
confirms the tripwire fires. Exit 0 when the grid is found and decoded
(the capture mode) or the self-test passes; 1 on failure. The STATS line
is always printed; the gate asserts on it.
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

def source_row_to_screen(row):
    """Convert one LSB-left source row to the decoder's MSB-left row."""
    screen = 0
    for x in range(8):
        if row & (1 << x):
            screen |= 1 << (7 - x)
    return screen

def assert_orientation_golden(font):
    """Independent asymmetric oracle for the source/decoder boundary."""
    c_source = (0x3c, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3c, 0x00)
    c_screen = (0x3c, 0x66, 0xc0, 0xc0, 0xc0, 0x66, 0x3c, 0x00)
    actual_source = tuple(font[ord("C") - 0x20])
    actual_screen = tuple(source_row_to_screen(row) for row in actual_source)
    if actual_source != c_source:
        raise AssertionError("font8x8 C source rows changed: %r" % (actual_source,))
    if actual_screen != c_screen:
        raise AssertionError(
            "LSB-left to MSB-left normalization mirrored C: %r" % (actual_screen,)
        )

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

# ------------------------------------------------ clock-window decode (G5)
# Shared by main() (the live decode) and self_test() (the offline in-cell
# mirror simulation): decode a fixed run of 8x8 glyphs at (ox, oy) with the
# given ink predicate, matched against the normalized forward or mirrored
# font. The clock window is at fixed framebuffer coordinates (960,16,
# 304x192): title "clock" at (968,22), body "DRIVING AWARD" at (968,42).

def clock_ink_dark(pr, pg, pb):
    return pr + pg + pb < 250  # dark title text on the amber bar

def clock_ink_amber(pr, pg, pb):
    return pr > pg > pb and pr > 120  # amber accent on navy (hue-specific)

def decode_clock_string(px, w, h, font, pitch, ox, oy, nchars, mirror, ink_fn):
    s = []
    for c in range(nchars):
        cell = []
        for rr in range(8):
            row = 0
            for bb in range(8):
                cx = ox + c * pitch + bb * pitch // 8
                cy = oy + rr * pitch // 8
                if 0 <= cx < w and 0 <= cy < h:
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
                # Captured rows are MSB-left; source rows are LSB-left.
                # A correct screen therefore matches the normalized row,
                # while an in-cell mirror matches the raw source byte.
                b = g[ri] if mirror else source_row_to_screen(g[ri])
                sc += bin(a ^ b).count("1")
            if sc < best_sc:
                best_sc, best_c = sc, idx
        s.append(chr(0x20 + best_c) if best_sc <= 10 else "?")
    return "".join(s)

def count_unknowns(s):
    return sum(1 for ch in s if ch == "?")

def self_test():
    """Offline in-cell mirror simulation (class A — no VZ boot needed).

    First pins the LSB-first source convention against an asymmetric C
    golden. Then renders the clock window's static strings with the kernel's
    intended LSB-first glyph walk, decodes them (must read 'clock' /
    'DRIVING AWARD'), mirrors each glyph in-cell (the old draw_glyph
    regression), re-decodes, and confirms the forward decode now reads
    garbage while the mirrored decode reads clean — the tripwire fires
    without a live VZ boot.
    """
    font = load_font()
    assert_orientation_golden(font)
    print("self-test: asymmetric C golden confirms source LSB-left orientation")
    w, h = 1280, 720
    buf = bytearray(w * h * 4)

    def put(x, y, r, g, b):
        if 0 <= x < w and 0 <= y < h:
            k = (y * w + x) * 4
            buf[k] = r
            buf[k + 1] = g
            buf[k + 2] = b
            buf[k + 3] = 0xff

    def px(x, y):
        if 0 <= x < w and 0 <= y < h:
            k = (y * w + x) * 4
            return buf[k], buf[k + 1], buf[k + 2]
        return 0, 0, 0

    # The clock window: navy body + amber title bar (the G5 palette).
    for y in range(16, 208):
        for x in range(960, 1264):
            put(x, y, 0x0a, 0x1a, 0x2e)          # navy body
    for y in range(18, 34):
        for x in range(962, 1262):
            put(x, y, 0xb5, 0x89, 0x00)          # amber title bar

    # The kernel's intended draw_glyph: source LSB-first, top-to-bottom.
    def draw_string(s, x0, y0, rgb):
        for i, ch in enumerate(s):
            g = font[ord(ch) - 0x20]
            for gy in range(8):
                bits = g[gy]
                for gx in range(8):
                    if bits & 0x01:
                        put(x0 + i * 8 + gx, y0 + gy, *rgb)
                    bits >>= 1

    draw_string("clock", 968, 22, (0x14, 0x14, 0x14))          # dark title
    draw_string("DRIVING AWARD", 968, 42, (0xff, 0xaa, 0x00))  # amber body

    def decode(mirror):
        t = decode_clock_string(px, w, h, font, 8, 968, 22, 5, mirror, clock_ink_dark)
        b = decode_clock_string(px, w, h, font, 8, 968, 42, 13, mirror, clock_ink_amber)
        return t, b

    t, b = decode(False)
    print("self-test: forward title=%r body=%r" % (t, b))
    if t != "clock" or b != "DRIVING AWARD":
        print("SELF-TEST FAIL: the synthetic clock window does not decode forward (title=%r body=%r)" % (t, b))
        sys.exit(1)

    # In-cell mirror: reverse each glyph's pixels within its 8x8 cell —
    # exactly what a draw_glyph bit-order regression produces (the text
    # stays in place, each glyph flips).
    for s, x0, y0 in (("clock", 968, 22), ("DRIVING AWARD", 968, 42)):
        for i in range(len(s)):
            for gy in range(8):
                row = [px(x0 + i * 8 + gx, y0 + gy) for gx in range(8)]
                for gx in range(8):
                    put(x0 + i * 8 + gx, y0 + gy, *row[7 - gx])

    t2, b2 = decode(False)
    tu = count_unknowns(t2)
    bu = count_unknowns(b2)
    print("self-test: after in-cell mirror, forward title=%r (%d unknowns) body=%r (%d unknowns)" % (t2, tu, b2, bu))
    # The gate's Phase 2d thresholds: a mirrored clock must fail the
    # semantic proof (no longer 'clock' / 'DRIVING AWARD') AND explode the
    # unknown counts (>= 3 of 5 title, >= 7 of 13 body).
    if t2 == "clock" or b2 == "DRIVING AWARD" or tu < 3 or bu < 7:
        print("SELF-TEST FAIL: the in-cell mirror was not detected (title=%r body=%r)" % (t2, b2))
        sys.exit(1)

    # The mirrored-DECODE leg must now read clean (the matcher can tell the
    # two orientations apart — a both-garbage regression would fail here).
    mt2, mb2 = decode(True)
    print("self-test: after in-cell mirror, mirrored decode title=%r body=%r" % (mt2, mb2))
    if mt2 != "clock" or mb2 != "DRIVING AWARD":
        print("SELF-TEST FAIL: mirrored decode after in-cell mirror did not read clean (title=%r body=%r)" % (mt2, mb2))
        sys.exit(1)

    print("SELF-TEST PASS: the clock title/body tripwire reads forward and detects an in-cell mirror")

# ------------------------------------------------------------------- main
def main():
    if "--self-test" in sys.argv:
        self_test()
        return
    path = sys.argv[1]
    mirror_lines = 3
    for i, a in enumerate(sys.argv[2:]):
        if a == "--mirror-lines":
            mirror_lines = int(sys.argv[i + 3])

    font = load_font()
    assert_orientation_golden(font)
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
                        b = (g[r] if mirror
                             else source_row_to_screen(g[r]))
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
    # too, so a flip anywhere fails mechanically (shared decode:
    # decode_clock_string + clock_ink_* above).
    cscale = pitch // 8
    clock_title = decode_clock_string(px, w, h, font, pitch, 968 * cscale, 22 * cscale, 5, False, clock_ink_dark)
    clock_title_m = decode_clock_string(px, w, h, font, pitch, 968 * cscale, 22 * cscale, 5, True, clock_ink_dark)
    clock_body = decode_clock_string(px, w, h, font, pitch, 968 * cscale, 42 * cscale, 13, False, clock_ink_amber)
    clock_body_m = decode_clock_string(px, w, h, font, pitch, 968 * cscale, 42 * cscale, 13, True, clock_ink_amber)

    ct_fwd_u = count_unknowns(clock_title)
    ct_mir_u = count_unknowns(clock_title_m)
    cb_fwd_u = count_unknowns(clock_body)
    cb_mir_u = count_unknowns(clock_body_m)

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
