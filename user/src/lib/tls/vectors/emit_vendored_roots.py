#!/usr/bin/env python3
"""Emit user/src/lib/tls/vendored_roots.zig from a set of DER certificates.

Usage: python3 emit_vendored_roots.py <version-string> <out.zig> <cert.der>...

Format: repeated `u16 big-endian length || DER`. The guest holds this in the
image, so the root set is static rather than fetched per connection.
"""
import pathlib
import sys

version = sys.argv[1]
out = pathlib.Path(sys.argv[2])
ders = [pathlib.Path(p).read_bytes() for p in sys.argv[3:]]
assert ders, "at least one certificate"
for d in ders:
    assert 0 < len(d) < 65536, "certificate too large for a u16 length"

L = []
L.append("//! Vendored trust anchors (ADR 0029 D5) — GENERATED, do not hand-edit.")
L.append("//!")
L.append("//! Format: repeated `u16 big-endian length || DER certificate`.")
L.append("")
L.append(f'pub const version = "{version}";')
L.append("")
for i, d in enumerate(ders):
    L.append(f"// anchor {i}: {len(d)} B DER")
    L.append("pub const anchor_%d = [_]u8{" % i)
    row = []
    for b in d:
        row.append(f"0x{b:02x},")
        if len(row) == 16:
            L.append("    " + " ".join(row)); row = []
    if row:
        L.append("    " + " ".join(row))
    L.append("};")
L.append("")
L.append("pub const blob = blk: {")
L.append("    var b: [%d]u8 = undefined;" % (sum(len(d) + 2 for d in ders)))
L.append("    var off: usize = 0;")
for i, d in enumerate(ders):
    L.append("    b[off] = 0x%02x;" % (len(d) >> 8))
    L.append("    b[off + 1] = 0x%02x;" % (len(d) & 0xFF))
    L.append("    off += 2;")
    L.append("    @memcpy(b[off..][0..%d], &anchor_%d);" % (len(d), i))
    L.append("    off += %d;" % len(d))
L.append("    break :blk b;")
L.append("};")
L.append("")
out.write_text("\n".join(L))
print("wrote", out, "with", len(ders), "anchor(s)")
