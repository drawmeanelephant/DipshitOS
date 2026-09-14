#!/usr/bin/env python3
"""Emit the Zig vector module from the Go-generated aes-vectors.json.

Inputs are trusted only in the sense that they came from gen_aesgcm.go in
this same directory, which asserts the published FIPS 197 / NIST GCM values
before writing anything. Values are transcribed verbatim as hex text; the
Zig tests decode them with std.fmt.hexToBytes.
"""
import json
import sys
import pathlib

here = pathlib.Path(__file__).resolve().parent
data = json.loads((here / "aes-vectors.json").read_text())
out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else here / "aes_gcm_vectors.zig"

L = []
w = L.append
w("//! AES / AES-GCM test vectors — GENERATED, do not hand-edit.")
w("//!")
w("//! Producer: go1.27.1 crypto/aes + cipher.NewGCM (see")
w("//! `vectors/gen_aesgcm.go` in the TLS work tree). The ECB set is")
w("//! additionally cross-checked against openssl 3.6.4 `enc -aes-*-ecb`; the")
w("//! generator aborts unless its own output matches FIPS 197 C.1/C.3 and")
w("//! NIST GCM test cases 1 and 2.")
w("//!")
w("//! Every value is hex text; the tests decode with std.fmt.hexToBytes.")
w("")
w("pub const EcbCase = struct {")
w("    name: []const u8,")
w("    key: []const u8,")
w("    pt: []const u8,")
w("    ct: []const u8,")
w("};")
w("")
w("pub const ecb = [_]EcbCase{")
for v in data["ecb"]:
    w("    .{ .name = %s, .key = %s, .pt = %s, .ct = %s }," % (
        json.dumps(v["name"]), json.dumps(v["key"]), json.dumps(v["pt"]), json.dumps(v["ct"])))
w("};")
w("")
w("pub const GcmCase = struct {")
w("    name: []const u8,")
w("    key: []const u8,")
w("    nonce: []const u8,")
w("    aad: []const u8,")
w("    pt: []const u8,")
w("    ct: []const u8,")
w("    tag: []const u8,")
w("};")
w("")
w("pub const gcm = [_]GcmCase{")
for v in data["gcm"]:
    w("    .{ .name = %s, .key = %s, .nonce = %s, .aad = %s, .pt = %s, .ct = %s, .tag = %s }," % (
        json.dumps(v["name"]), json.dumps(v["key"]), json.dumps(v["nonce"]),
        json.dumps(v["aad"]), json.dumps(v["pt"]), json.dumps(v["ct"]), json.dumps(v["tag"])))
w("};")
w("")

out.write_text("\n".join(L))
print("wrote", out, len("\n".join(L)), "bytes;", len(data["ecb"]), "ecb,", len(data["gcm"]), "gcm")
