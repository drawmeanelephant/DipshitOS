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
L.append("")
L.append("const std = @import(\"std\");")
L.append("const x509 = @import(\"x509.zig\");")
L.append("const store_mod = @import(\"trust_store.zig\");")
L.append("")
L.append("// The blob is the guest's only source of trust, so its framing is asserted")
L.append("// rather than assumed: every byte is consumed by a length-prefixed DER")
L.append("// certificate, each anchor parses as a CA, and each loads into the same")
L.append("// `TrustStore` type the client validates against. A truncation or a stray")
L.append("// byte is a test failure here, not a silent empty store on the guest.")
L.append("test \"vendored_roots: the blob frames, parses, and loads as an anchor\" {")
L.append("    var off: usize = 0;")
L.append("    var anchors: usize = 0;")
L.append("    var s = store_mod.TrustStore{};")
L.append("    while (off + 2 <= blob.len) {")
L.append("        const len = std.mem.readInt(u16, blob[off..][0..2], .big);")
L.append("        off += 2;")
L.append("        try std.testing.expect(len > 0);")
L.append("        try std.testing.expect(off + len <= blob.len);")
L.append("        const der = blob[off..][0..len];")
L.append("        var cert: x509.Cert = .{};")
L.append("        try x509.Cert.parse(der, &cert);")
L.append("        try std.testing.expect(cert.is_ca);")
L.append("        try std.testing.expectEqualStrings(\"AutoClaw Test Root CA\", cert.subject_cn.?);")
L.append("        try s.addRoot(der);")
L.append("        off += len;")
L.append("        anchors += 1;")
L.append("    }")
L.append("    try std.testing.expectEqual(blob.len, off);")
L.append("    try std.testing.expectEqual(@as(usize, 1), anchors);")
L.append("    try std.testing.expectEqual(@as(usize, 1), s.rootCount());")
L.append("    s.setVersion(version);")
L.append("    try std.testing.expectEqualStrings(version, s.versionString());")
L.append("}")
L.append("")
out.write_text("\n".join(L))
print("wrote", out, "with", len(ders), "anchor(s)")
