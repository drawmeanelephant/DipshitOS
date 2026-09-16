#!/usr/bin/env python3
"""Emit user/src/lib/tls/vendored_roots.zig from a set of DER certificates.

Usage:
  python3 emit_vendored_roots.py <version-string> <out.zig> <cert.der>...
  python3 emit_vendored_roots.py --check <version-string> <out.zig> <cert.der>...

Format: repeated `u16 big-endian length || DER`. The guest holds this in the
image, so the root set is static rather than fetched per connection.

Pinning rule
------------
FETCHS.BIN vendors this blob at build time. The committed DER under
vectors/fx/ (root.pem, converted to DER) MUST match the `anchor_0` bytes in
vendored_roots.zig. openssl genkey in make_x509_fixtures.sh produces a
fresh random CA every run; emitting a new zig file from a regenerated
root silently desyncs the guest trust store from the live-tls13 fixtures
and the handshake fails closed (ChainValidationFailed).

`--check` compares the given DER against the existing zig file and writes
nothing. It is the loud path: a fresh regen fails, the committed fx/ set
passes. Default emit still overwrites out.zig — that is an intentional
root rotation, not a fixture regen, and must land together with a new
committed fx/ set.
"""
import hashlib
import pathlib
import re
import sys

ANCHOR_RE = re.compile(r"pub const anchor_(\d+) = \[_]u8\{(.*?)\};", re.S)


def usage(code: int = 2) -> None:
    sys.stderr.write(
        "Usage: python3 emit_vendored_roots.py [--check] "
        "<version-string> <out.zig> <cert.der>...\n"
    )
    sys.exit(code)


def load_ders(paths: list[str]) -> list[bytes]:
    ders = [pathlib.Path(p).read_bytes() for p in paths]
    if not ders:
        sys.exit("emit_vendored_roots.py: at least one certificate is required")
    for d in ders:
        if not (0 < len(d) < 65536):
            sys.exit("emit_vendored_roots.py: certificate too large for a u16 length")
    return ders


def parse_anchors(zig_text: str) -> list[bytes]:
    found = sorted(ANCHOR_RE.finditer(zig_text), key=lambda m: int(m.group(1)))
    anchors = []
    for m in found:
        hex_bytes = re.findall(r"0x([0-9a-fA-F]{2})", m.group(2))
        anchors.append(bytes(int(h, 16) for h in hex_bytes))
    return anchors


def digest(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def check(version: str, out: pathlib.Path, ders: list[bytes]) -> int:
    if not out.is_file():
        sys.stderr.write("emit_vendored_roots.py --check: missing %s\n" % out)
        return 1
    text = out.read_text()
    pinned = parse_anchors(text)
    if not pinned:
        sys.stderr.write(
            "emit_vendored_roots.py --check: no pub const anchor_N in %s\n" % out
        )
        return 1
    ver_m = re.search(r'^pub const version = "([^"]*)";$', text, re.M)
    pinned_version = ver_m.group(1) if ver_m else ""
    failed = False
    if pinned_version != version:
        sys.stderr.write(
            "ERROR: version string does not match %s\n"
            "  given:  %s\n"
            "  pinned: %s\n" % (out, version, pinned_version)
        )
        failed = True
    if len(pinned) != len(ders):
        sys.stderr.write(
            "ERROR: anchor count does not match %s\n"
            "  given:  %d\n"
            "  pinned: %d\n" % (out, len(ders), len(pinned))
        )
        failed = True
    for i, der in enumerate(ders):
        pin = pinned[i] if i < len(pinned) else b""
        if der == pin:
            sys.stderr.write(
                "OK: anchor_%d matches (%d bytes, sha256=%s)\n"
                % (i, len(der), digest(der))
            )
            continue
        sys.stderr.write(
            "ERROR: given DER does not match vendored anchor_%d in %s\n"
            "  given:  %d bytes sha256=%s\n"
            "  pinned: %d bytes sha256=%s\n"
            "openssl genkey produces a fresh random CA every run. The committed\n"
            "vectors/fx/ set is the live identity FETCHS.BIN vendors at build time.\n"
            "Do not overwrite fx/; do not re-emit vendored_roots.zig unless you\n"
            "intentionally rotate the guest trust store and land both together.\n"
            % (i, out, len(der), digest(der), len(pin), digest(pin) if pin else "none")
        )
        failed = True
    return 1 if failed else 0


def emit_text(version: str, ders: list[bytes]) -> str:
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
    return "\n".join(L)


def main(argv: list[str]) -> int:
    check_mode = False
    if argv and argv[0] in ("-h", "--help"):
        usage(0)
    if argv and argv[0] == "--check":
        check_mode = True
        argv = argv[1:]
    if len(argv) < 3:
        usage(2)
    version, out_s, *der_paths = argv
    out = pathlib.Path(out_s)
    ders = load_ders(der_paths)
    if check_mode:
        return check(version, out, ders)
    out.write_text(emit_text(version, ders))
    print("wrote", out, "with", len(ders), "anchor(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
