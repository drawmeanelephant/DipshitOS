#!/usr/bin/env python3
"""Emit user/src/lib/tls/x509_vectors.zig from the OpenSSL-generated fixtures.

Every expected value is read out of `openssl x509` output — nothing is
hand-written. The DER for each certificate is embedded as hex.

Usage: python3 emit_x509_vectors.py <fx-dir> <out.zig>
"""
import datetime
import pathlib
import re
import subprocess
import sys

fx = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "fx").resolve()
out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "x509_vectors.zig")

# (file stem, expected subject CN, expected SAN dNSName count, expected ip count,
#  expected is_ca, expected unknown-critical count)
FIXTURES = [
    ("root", "AutoClaw Test Root CA", 0, 0, True, 0),
    ("inter", "AutoClaw Test Intermediate CA", 0, 0, True, 0),
    ("leaf-ec", "leaf.example.com", 2, 0, False, 0),
    ("leaf-rsa", "rsa.example.com", 1, 0, False, 0),
    ("leaf-ip", "ip.example.com", 0, 2, False, 0),
    ("ca-nc", "AutoClaw Name-Constrained CA", 0, 0, True, 0),
    ("leaf-nc", "nc.example.com", 1, 0, False, 0),
    ("leaf-unknowncrit", "unknown.example.com", 1, 0, False, 1),
    ("leaf-nosan", "cnonly.example.com", 0, 0, False, 0),
    ("leaf-ncevil", "evil.example.com", 1, 0, False, 0),
    ("leaf-ncother", "other.example", 1, 0, False, 0),
]

UNKNOWN_OID = "1.3.6.1.4.1.55555.1"


def run(*args) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def text(der: pathlib.Path) -> str:
    return run("openssl", "x509", "-inform", "der", "-in", str(der), "-noout", "-text")


def name_cn(s: str) -> str:
    m = re.search(r"CN=([^,\n]+)", s)
    if not m:
        sys.exit(f"no CN in {s!r}")
    return m.group(1)


def to_epoch(s: str) -> int:
    dt = datetime.datetime.strptime(s.strip(), "%b %d %H:%M:%S %Y %Z")
    return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())


rows = []
for stem, exp_cn, exp_dns, exp_ip, exp_ca, exp_unk in FIXTURES:
    der = fx / f"{stem}.der"
    pem = fx / f"{stem}.pem"
    if not der.exists():
        sys.exit(f"missing {der}")
    t = text(der)

    version = int(re.search(r"Version:\s*(\d+)", t).group(1))
    serial = re.search(r"Serial Number:\s*\n?\s*([0-9a-fA-F:]+)", t).group(1).replace(":", "").lower()
    subject = run("openssl", "x509", "-inform", "der", "-in", str(der), "-noout", "-subject", "-nameopt", "RFC2253")
    issuer = run("openssl", "x509", "-inform", "der", "-in", str(der), "-noout", "-issuer", "-nameopt", "RFC2253")
    subj_cn = name_cn(subject)
    iss_cn = name_cn(issuer)
    if subj_cn != exp_cn:
        sys.exit(f"{stem}: subject CN {subj_cn!r} != expected {exp_cn!r}")

    dates = run("openssl", "x509", "-inform", "der", "-in", str(der), "-noout", "-dates")
    nb = to_epoch(re.search(r"notBefore=(.*)", dates).group(1))
    na = to_epoch(re.search(r"notAfter=(.*)", dates).group(1))

    if "Public Key Algorithm: id-ecPublicKey" in t:
        kind = "ec"
    elif "Public Key Algorithm: rsaEncryption" in t:
        kind = "rsa"
    elif "ED25519" in t.upper():
        kind = "ed25519"
    else:
        kind = "unsupported"

    # basicConstraints
    is_ca = "CA:TRUE" in t
    if is_ca != exp_ca:
        sys.exit(f"{stem}: CA {is_ca} != expected {exp_ca}")

    # SAN counts, straight from the extension text
    san_block = re.search(r"X509v3 Subject Alternative Name[^\n]*\n\s*(.+)", t)
    dns_n = ip_n = 0
    has_san = san_block is not None
    if has_san:
        line = san_block.group(1)
        dns_n = len(re.findall(r"DNS:", line))
        ip_n = len(re.findall(r"IP Address:", line))
    if dns_n != exp_dns or ip_n != exp_ip:
        sys.exit(f"{stem}: SAN dns={dns_n} ip={ip_n} != expected {exp_dns}/{exp_ip}")

    # unknown critical extension
    unk = len(re.findall(rf"^\s*{re.escape(UNKNOWN_OID)}: critical", t, re.M))
    if unk != exp_unk:
        sys.exit(f"{stem}: unknown-critical {unk} != expected {exp_unk}")

    der_hex = der.read_bytes().hex()
    pem_text = pem.read_text() if pem.exists() else ""
    rows.append(dict(name=stem, der_hex=der_hex, pem_text=pem_text, version=version,
                     subject_cn=subj_cn, issuer_cn=iss_cn, not_before=nb, not_after=na,
                     is_ca=is_ca, has_san=has_san, san_dns_len=dns_n, serial_hex=serial,
                     key_kind=kind, unknown_critical_len=unk))
    print(f"  {stem:18s} v{version} cn={subj_cn:32s} ca={is_ca!s:5s} san={dns_n}/{ip_n} unk={unk}",
          file=sys.stderr)

max_der = max(len(r["der_hex"]) // 2 for r in rows)
max_pem = max(len(r["pem_text"]) for r in rows)

L = []
w = L.append
w("//! X.509 fixtures for the in-tree TLS 1.3 client — GENERATED, do not hand-edit.")
w("//!")
w("//! Produced by `vectors/make_x509_fixtures.sh` (OpenSSL 3.6.4) and")
w("//! `vectors/emit_x509_vectors.py`, which reads every expected value out of")
w("//! `openssl x509 -text` and refuses to emit if a count or a name disagrees")
w("//! with what the fixture set is supposed to contain.")
w("//!")
w("//! DER is hex text; the tests decode with std.fmt.hexToBytes.")
w("")
w(f"pub const max_der_len = {max_der};")
w(f"pub const max_pem_len = {max_pem};")
w("")
w("pub const CertVector = struct {")
w("    name: []const u8,")
w("    der_hex: []const u8,")
w("    pem: []const u8,")
w("    version: u8,")
w("    subject_cn: []const u8,")
w("    issuer_cn: []const u8,")
w("    not_before: i64,")
w("    not_after: i64,")
w("    is_ca: bool,")
w("    has_san: bool,")
w("    san_dns_len: usize,")
w("    unknown_critical_len: usize,")
w("    serial_hex: []const u8,")
w("    key_kind: []const u8,")
w("};")
w("")
w("pub const certs = [_]CertVector{")
import json
for r in rows:
    w("    .{")
    w(f"        .name = {json.dumps(r['name'])},")
    w(f"        .der_hex = {json.dumps(r['der_hex'])},")
    w(f"        .pem = {json.dumps(r['pem_text'])},")
    w(f"        .version = {r['version']},")
    w(f"        .subject_cn = {json.dumps(r['subject_cn'])},")
    w(f"        .issuer_cn = {json.dumps(r['issuer_cn'])},")
    w(f"        .not_before = {r['not_before']},")
    w(f"        .not_after = {r['not_after']},")
    w(f"        .is_ca = {str(r['is_ca']).lower()},")
    w(f"        .has_san = {str(r['has_san']).lower()},")
    w(f"        .san_dns_len = {r['san_dns_len']},")
    w(f"        .unknown_critical_len = {r['unknown_critical_len']},")
    w(f"        .serial_hex = {json.dumps(r['serial_hex'])},")
    w(f"        .key_kind = {json.dumps(r['key_kind'])},")
    w("    },")
w("};")
w("")
w("/// Lookup by fixture name; the tests use this instead of an index so a")
w("/// reordering cannot silently point a test at the wrong certificate.")
w("pub fn byName(name: []const u8) *const CertVector {")
w("    for (&certs) |*c| {")
w("        if (std.mem.eql(u8, c.name, name)) return c;")
w("    }")
w("    unreachable;")
w("}")
w("")
w('const std = @import("std");')
w("")

out.write_text("\n".join(L))
print(f"wrote {out}: {len(rows)} vectors, max der {max_der} B, max pem {max_pem} B", file=sys.stderr)
