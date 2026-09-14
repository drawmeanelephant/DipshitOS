#!/usr/bin/env python3
"""Generate ECDSA vectors (curve constants + OpenSSL signatures) for C2.

The curve constants are read out of `openssl ecparam -param_enc explicit`
rather than transcribed; the signatures are produced by `openssl dgst -sign`
and asserted to verify before being emitted, with a mutated-signature case
asserted NOT to verify.

Usage: python3 emit_ecdsa_vectors.py <fx-dir> <out.zig>
"""
import pathlib
import re
import subprocess
import sys
import json

fx = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "fx-ecdsa").resolve()
out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "ecdsa_vectors.zig").resolve()
fx.mkdir(parents=True, exist_ok=True)


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def even(s: str) -> str:
    s = "".join(s.split()).lower().replace(":", "")
    return "0" + s if len(s) % 2 else s


def curve_params(name):
    text = sh("openssl", "ecparam", "-name", name, "-param_enc", "explicit", "-text", "-noout").stdout
    lines = text.splitlines()

    def grab(label):
        for idx, ln in enumerate(lines):
            if ln.startswith(label):
                hexs = []
                j = idx + 1
                while j < len(lines) and (lines[j].startswith(" ") or lines[j].startswith("\t")):
                    hexs += re.findall(r"[0-9a-fA-F]{2}", lines[j])
                    j += 1
                if not hexs:
                    raise AssertionError((name, label, "empty"))
                return even("".join(hexs))
        raise AssertionError((name, label, "not found"))

    p = grab("Prime")
    b = grab("B:")
    gen = grab("Generator")
    # Generator is 04 || X || Y; strip the 0x04 tag and split the field-size halves.
    gen_clean = gen[2:]
    gx = gen_clean[:len(gen_clean) // 2]
    gy = gen_clean[len(gen_clean) // 2:]
    order = grab("Order")
    return dict(p=p, b=b, gx=gx, gy=gy, n=order)


def gen_sig(curve, hashname, label):
    kp = fx / f"{label}.pem"
    subprocess.run(["openssl", "ecparam", "-name", curve, "-genkey", "-noout", "-out", str(kp)], capture_output=True, check=True)
    msg = f"ECDSA test vector: {curve} over {hashname}"
    m = fx / f"{label}.msg"
    m.write_text(msg)
    sig = fx / f"{label}.sig"
    subprocess.run(["openssl", "dgst", f"-{hashname}", "-sign", str(kp), "-out", str(sig), str(m)], capture_output=True, check=True)
    # assert verifies
    v = sh("openssl", "dgst", f"-{hashname}", "-verify", str(kp), "-signature", str(sig), str(m)).stdout
    assert "Verified OK" in v
    # assert a mutated signature does not
    bad = bytearray(sig.read_bytes()); bad[-1] ^= 1
    badsig = fx / f"{label}.bad.sig"; badsig.write_bytes(bytes(bad))
    vb = subprocess.run(["openssl", "dgst", f"-{hashname}", "-verify", str(kp), "-signature", str(badsig), str(m)], capture_output=True, text=True)
    assert "Verified OK" not in (vb.stdout + vb.stderr)

    pub = sh("openssl", "ec", "-in", str(kp), "-pubout", "-text", "-noout").stdout
    pub_lines = pub.splitlines()
    pubhex = ""
    for i, ln in enumerate(pub_lines):
        if ln.startswith("pub:"):
            toks = []
            j = i + 1
            while j < len(pub_lines) and (pub_lines[j].startswith(" ") or pub_lines[j].startswith("\t")):
                toks += re.findall(r"[0-9a-fA-F]{2}", pub_lines[j])
                j += 1
            pubhex = even("".join(toks))
            break
    assert pubhex, "no pub point found"
    # uncompressed point is 04 || X || Y, each field size bytes
    flen = (len(pubhex) - 2) // 2
    px = pubhex[2:2 + flen]
    py = pubhex[2 + flen:]

    # parse the DER ECDSA-Sig-Value: SEQUENCE { INTEGER r, INTEGER s }
    sigder = sig.read_bytes()
    r, s = parse_ecdsa_sig(sigder)
    return dict(label=label, curve=curve, hash=hashname, msg=msg,
                pubx=px, puby=py, r=even(f"{r:x}"), s=even(f"{s:x}"), sig_hex=sigder.hex())


def parse_ecdsa_sig(der):
    # minimal DER: 30 len 02 rlen r 02 slen s
    assert der[0] == 0x30, der[:2].hex()
    i = 2
    assert der[i] == 0x02, der.hex()
    rlen = der[i + 1]; i += 2
    r = int.from_bytes(der[i:i + rlen], "big"); i += rlen
    assert der[i] == 0x02
    slen = der[i + 1]; i += 2
    s = int.from_bytes(der[i:i + slen], "big")
    return r, s


rows = {}
for name in ("prime256v1", "secp384r1"):
    rows[name] = curve_params(name)

sigs = [
    gen_sig("prime256v1", "sha256", "p256-sha256-a"),
    gen_sig("prime256v1", "sha256", "p256-sha256-b"),
    gen_sig("secp384r1", "sha384", "p384-sha384-a"),
    gen_sig("secp384r1", "sha384", "p384-sha384-b"),
]

L = []
w = L.append
w("//! ECDSA vectors — GENERATED, do not hand-edit.")
w("//!")
w("//! Curve constants come from `openssl ecparam -param_enc explicit -text`;")
w("//! signatures from `openssl dgst -sign`, each asserted to verify (and the")
w("//! mutated-signature case asserted not to) before this file was written.")
w("")
w("pub const Curves = struct {")
w("    p: []const u8,")
w("    b: []const u8,")
w("    n: []const u8,")
w("    gx: []const u8,")
w("    gy: []const u8,")
w("};")
w("")
w("pub const p256 = Curves{")
for k in ("p", "b", "n", "gx", "gy"):
    w(f"    .{k} = {json.dumps(rows['prime256v1'][k])},")
w("};")
w("pub const p384 = Curves{")
for k in ("p", "b", "n", "gx", "gy"):
    w(f"    .{k} = {json.dumps(rows['secp384r1'][k])},")
w("};")
w("")
w("pub const SigCase = struct {")
w("    label: []const u8,")
w("    curve: []const u8,")
w("    hash: []const u8,")
w("    msg: []const u8,")
w("    pubx: []const u8,")
w("    puby: []const u8,")
w("    r: []const u8,")
w("    s: []const u8,")
w("    sig_hex: []const u8,")
w("};")
w("")
w("pub const sigs = [_]SigCase{")
for s in sigs:
    w("    .{")
    w(f"        .label = {json.dumps(s['label'])},")
    w(f"        .curve = {json.dumps(s['curve'])},")
    w(f"        .hash = {json.dumps(s['hash'])},")
    w(f"        .msg = {json.dumps(s['msg'])},")
    w(f"        .pubx = {json.dumps(s['pubx'])},")
    w(f"        .puby = {json.dumps(s['puby'])},")
    w(f"        .r = {json.dumps(s['r'])},")
    w(f"        .s = {json.dumps(s['s'])},")
    w(f"        .sig_hex = {json.dumps(s['sig_hex'])},")
    w("    },")
w("};")
w("")
out.write_text("\n".join(L))
print(f"wrote {out}: 2 curves, {len(sigs)} signatures", file=sys.stderr)
