#!/usr/bin/env python3
"""Generate the RSA / bigint vector modules for the in-tree TLS 1.3 client (C2).

Every expected value comes from a real implementation:
  * modexp vectors: Python 3.14 `pow(base, exp, mod)` — an independent bignum;
  * RSA key material and signatures: OpenSSL 3.6.4 (`genrsa`, `dgst -sign`),
    covering PKCS#1 v1.5 and PSS for SHA-256/384/512, at 2048 and 4096 bits.

The script asserts each signature verifies with `openssl dgst -verify` before
emitting anything, so a fixture that does not actually verify cannot be pinned.

Usage: python3 emit_rsa_vectors.py <fx-dir> <out-dir>
"""
import json
import pathlib
import re
import subprocess
import sys

fx = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "fx-rsa").resolve()
outdir = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else ".").resolve()
fx.mkdir(parents=True, exist_ok=True)


def even(s: str) -> str:
    """Hex strings must have an even number of digits for the Zig decoder."""
    s = s.lower()
    return "0" + s if len(s) % 2 else s


def sha(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def sh(*args, stdin=None):
    return subprocess.run(args, capture_output=True, text=True, check=True, input=stdin)


CASES = [
    # (name, bits, hash, padding, saltlen, message)
    ("rsa2048-sha256-pkcs1", 2048, "sha256", "pkcs1", None, "TLS 1.3 in-tree client: PKCS#1 v1.5 over SHA-256"),
    ("rsa2048-sha384-pkcs1", 2048, "sha384", "pkcs1", None, "TLS 1.3 in-tree client: PKCS#1 v1.5 over SHA-384"),
    ("rsa2048-sha512-pkcs1", 2048, "sha512", "pkcs1", None, "TLS 1.3 in-tree client: PKCS#1 v1.5 over SHA-512"),
    ("rsa2048-sha256-pss", 2048, "sha256", "pss", 32, "TLS 1.3 in-tree client: PSS over SHA-256"),
    ("rsa2048-sha384-pss", 2048, "sha384", "pss", 48, "TLS 1.3 in-tree client: PSS over SHA-384"),
    ("rsa2048-sha256-pss-max", 2048, "sha256", "pss", 222, "PSS with the maximum salt for SHA-256/2048"),
    ("rsa3072-sha256-pkcs1", 3072, "sha256", "pkcs1", None, "TLS 1.3 in-tree client: 3072-bit PKCS#1 v1.5"),
    ("rsa4096-sha256-pss", 4096, "sha256", "pss", 32, "TLS 1.3 in-tree client: 4096-bit PSS"),
    ("rsa4096-sha512-pkcs1", 4096, "sha512", "pkcs1", None, "TLS 1.3 in-tree client: 4096-bit PKCS#1 v1.5 over SHA-512"),
]

rows = []
keys = {}
for name, bits, h, pad, salt, msg in CASES:
    kp = fx / f"key{bits}.pem"
    if bits not in keys:
        subprocess.run(["openssl", "genrsa", "-out", str(kp), str(bits)], capture_output=True, check=True)
        mod = sha(["openssl", "rsa", "-in", str(kp), "-noout", "-modulus"]).strip()
        n_hex = mod.split("=", 1)[1].lower()
        pub = sha(["openssl", "rsa", "-in", str(kp), "-pubout", "-text", "-noout"])
        e = re.search(r"Exponent:\s*\d+\s*\(0x([0-9a-fA-F]+)\)", pub)
        assert e, pub
        keys[bits] = (n_hex, e.group(1).lower())

    m = fx / f"{name}.msg"
    m.write_text(msg)
    sig = fx / f"{name}.sig"
    cmd = ["openssl", "dgst", f"-{h}"]
    if pad == "pss":
        cmd += ["-sigopt", "rsa_padding_mode:pss", "-sigopt", f"rsa_pss_saltlen:{salt}"]
    cmd += ["-sign", str(kp), "-out", str(sig), str(m)]
    subprocess.run(cmd, capture_output=True, check=True)

    # Assert it verifies before we pin it.
    vcmd = ["openssl", "dgst", f"-{h}"]
    if pad == "pss":
        vcmd += ["-sigopt", "rsa_padding_mode:pss", "-sigopt", f"rsa_pss_saltlen:{salt}"]
    vcmd += ["-verify", str(fx / f"key{bits}.pem"), "-signature", str(sig), str(m)]
    vout = sha(vcmd)
    assert "Verified OK" in vout, (name, vout)

    # And assert a mutated signature does NOT verify (so the negative case is real).
    bad = bytearray(sig.read_bytes())
    bad[-1] ^= 0x01
    badsig = fx / f"{name}.bad.sig"
    badsig.write_bytes(bytes(bad))
    bcmd = list(vcmd)
    bcmd[bcmd.index("-signature") + 1] = str(badsig)
    bout = subprocess.run(bcmd, capture_output=True, text=True)
    assert "Verified OK" not in (bout.stdout + bout.stderr), (name, "mutated signature verified!")

    n_hex, e_hex = keys[bits]
    rows.append(dict(name=name, bits=bits, hash=h, padding=pad, salt=salt if salt is not None else -1,
                     msg=msg, n_hex=even(n_hex), e_hex=even(e_hex),
                     sig_hex=even(sig.read_bytes().hex())))
    print(f"  {name:26s} {bits}b {h} {pad} verified + negative ok", file=sys.stderr)

# ---- bigint modexp vectors, python's independent bignum ----
mods = {
    "mod128": 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF61,
    "mod256": 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF,
    "mod512": (1 << 512) - 189,
    "mod2048_rsa_n": int(keys[2048][0], 16),
}
bases = {
    "base_small": 0x123456789ABCDEF,
    "base_255": (1 << 255) - 19,
    "base_512": (1 << 512) - 9,
}
exps = {"exp_small": 65537, "exp_mid": (1 << 128) + 1, "exp_large": int(keys[2048][1], 16)}

bn = []
for mn, m in mods.items():
    for bnx, b in bases.items():
        if b >= m:
            continue
        for en, e in exps.items():
            if e > (1 << 300) and mn != "mod2048_rsa_n":
                continue
            r = pow(b % m, e, m)
            bn.append(dict(name=f"{mn}/{bnx}/{en}", mod_hex=even(f"{m:x}"), base_hex=even(f"{b % m:x}"),
                           exp_hex=even(f"{e:x}"), res_hex=even(f"{r:x}")))
print(f"  {len(bn)} modexp vectors", file=sys.stderr)


def zig(outpath, rows, bn):
    L = []
    w = L.append
    w("//! RSA / bigint vectors — GENERATED, do not hand-edit.")
    w("//!")
    w("//! RSA key material and signatures were produced with OpenSSL 3.6.4 and each")
    w("//! one was asserted to verify (with the matching mutated-signature case")
    w("//! asserted NOT to verify) before this file was written. The modexp vectors")
    w("//! come from Python 3.14 `pow()`, an independent bignum implementation.")
    w("")
    w("pub const RsaCase = struct {")
    w("    name: []const u8,")
    w("    bits: usize,")
    w("    hash: []const u8,")
    w("    padding: []const u8,")
    w("    salt_len: i32,")
    w("    msg: []const u8,")
    w("    n_hex: []const u8,")
    w("    e_hex: []const u8,")
    w("    sig_hex: []const u8,")
    w("};")
    w("")
    w("pub const rsa = [_]RsaCase{")
    for r in rows:
        w("    .{")
        w(f"        .name = {json.dumps(r['name'])},")
        w(f"        .bits = {r['bits']},")
        w(f"        .hash = {json.dumps(r['hash'])},")
        w(f"        .padding = {json.dumps(r['padding'])},")
        w(f"        .salt_len = {r['salt']},")
        w(f"        .msg = {json.dumps(r['msg'])},")
        w(f"        .n_hex = {json.dumps(r['n_hex'])},")
        w(f"        .e_hex = {json.dumps(r['e_hex'])},")
        w(f"        .sig_hex = {json.dumps(r['sig_hex'])},")
        w("    },")
    w("};")
    w("")
    w("pub const ModexpCase = struct {")
    w("    name: []const u8,")
    w("    mod_hex: []const u8,")
    w("    base_hex: []const u8,")
    w("    exp_hex: []const u8,")
    w("    res_hex: []const u8,")
    w("};")
    w("")
    w("pub const modexp = [_]ModexpCase{")
    for r in bn:
        w(f"    .{{ .name = {json.dumps(r['name'])}, .mod_hex = {json.dumps(r['mod_hex'])}, .base_hex = {json.dumps(r['base_hex'])}, .exp_hex = {json.dumps(r['exp_hex'])}, .res_hex = {json.dumps(r['res_hex'])} }},")
    w("};")
    w("")
    outpath.write_text("\n".join(L))
    print(f"wrote {outpath}: {len(rows)} RSA cases, {len(bn)} modexp cases", file=sys.stderr)


zig(outdir / "rsa_vectors.zig", rows, bn)
