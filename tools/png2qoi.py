#!/usr/bin/env python3
"""Convert standard images (PNG, JPG) to Quite OK Image (QOI) format.

Usage:
    python3 tools/png2qoi.py input.png output.qoi
"""

import sys
import struct
from PIL import Image

def encode_qoi(img: Image.Image) -> bytes:
    img = img.convert("RGBA")
    width, height = img.size
    pixels = list(img.getdata())

    out = bytearray()
    # 14-byte header: "qoif", width (BE), height (BE), channels (4), colorspace (0)
    out.extend(b"qoif")
    out.extend(struct.pack(">II", width, height))
    out.append(4)  # RGBA
    out.append(0)  # sRGB with linear alpha

    index = [(0, 0, 0, 0)] * 64
    prev = (0, 0, 0, 255)
    run = 0

    for px in pixels:
        r, g, b, a = px
        if (r, g, b, a) == prev:
            run += 1
            if run == 62:
                out.append(0b11000000 | (run - 1))
                run = 0
            continue

        if run > 0:
            out.append(0b11000000 | (run - 1))
            run = 0

        idx_pos = (r * 3 + g * 5 + b * 7 + a * 11) % 64
        if index[idx_pos] == (r, g, b, a):
            out.append(0b00000000 | idx_pos)
        else:
            index[idx_pos] = (r, g, b, a)
            if a == prev[3]:
                dr = (r - prev[0]) & 0xFF
                dg = (g - prev[1]) & 0xFF
                db = (b - prev[2]) & 0xFF

                # Convert to signed 8-bit
                s_dr = dr if dr < 128 else dr - 256
                s_dg = dg if dg < 128 else dg - 256
                s_db = db if db < 128 else db - 256

                if -2 <= s_dr <= 1 and -2 <= s_dg <= 1 and -2 <= s_db <= 1:
                    out.append(0b01000000 | ((s_dr + 2) << 4) | ((s_dg + 2) << 2) | (s_db + 2))
                else:
                    dr_dg = s_dr - s_dg
                    db_dg = s_db - s_dg
                    if -32 <= s_dg <= 31 and -8 <= dr_dg <= 7 and -8 <= db_dg <= 7:
                        out.append(0b10000000 | (s_dg + 32))
                        out.append(((dr_dg + 8) << 4) | (db_dg + 8))
                    else:
                        out.append(0xFE)
                        out.extend([r, g, b])
            else:
                out.append(0xFF)
                out.extend([r, g, b, a])

        prev = (r, g, b, a)

    if run > 0:
        out.append(0b11000000 | (run - 1))

    # 8-byte end marker
    out.extend(b"\x00\x00\x00\x00\x00\x00\x00\x01")
    return bytes(out)

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input> <output.qoi>", file=sys.stderr)
        sys.exit(1)

    inp = sys.argv[1]
    out_path = sys.argv[2]
    img = Image.open(inp)
    qoi_bytes = encode_qoi(img)
    with open(out_path, "wb") as f:
        f.write(qoi_bytes)
    print(f"Wrote {len(qoi_bytes)} bytes to {out_path}")

if __name__ == "__main__":
    main()
