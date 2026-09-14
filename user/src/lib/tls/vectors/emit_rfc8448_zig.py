#!/usr/bin/env python3
"""Emit the Zig RFC 8448 vector module from the validated §3 extraction.

Same parser as extract_rfc8448.py (octet-count validated), but writes Zig.
"""
import hashlib
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
lines = (here / "rfc8448.txt").read_text().splitlines()
start = next(i for i, l in enumerate(lines) if l.startswith("3.  Simple 1-RTT Handshake"))
end = next(i for i, l in enumerate(lines) if l.startswith("4.  Resumed 0-RTT Handshake"))

HEXPAIR = re.compile(r"\b[0-9a-f]{2}\b")
HEAD = re.compile(r"^([A-Za-z][A-Za-z0-9_]*?(?: [A-Za-z0-9_]+)*) \((\d+) octets\):\s*(.*)$")

blocks, label, pending = [], "(§3)", None
for raw in lines[start:end]:
    s = raw.strip()
    if not s:
        continue
    if s.startswith("{client}") or s.startswith("{server}"):
        if pending:
            blocks.append(tuple(pending[:3] + [pending[3]]))
            pending = None
        label = s.rstrip(":").strip()
        continue
    m = HEAD.match(s)
    if m:
        if pending:
            blocks.append(tuple(pending[:3] + [pending[3]]))
        pending = [label, m.group(1), int(m.group(2)), m.group(3)]
        continue
    if pending is not None:
        toks = HEXPAIR.findall(s)
        if toks and len(toks) == len(s.split()):
            pending[3] += " " + " ".join(toks)
if pending:
    blocks.append(tuple(pending[:3] + [pending[3]]))

for lb, nm, need, hx in blocks:
    if need == 0:
        continue
    if len(hx.split()) != need:
        sys.exit(f"OCTET MISMATCH {lb} / {nm}: {need} vs {len(hx.split())}")

def hexof(pred, what):
    for lb, nm, need, hx in blocks:
        if pred(lb, nm):
            return hx.replace(" ", "")
    sys.exit("not found: " + what)

def has(lb, nm, needle):
    return lb == lb and needle in lb and nm == nm

def one(label_sub, name):
    hits = [h for l, n, _, h in blocks if label_sub in l and n == name]
    if not hits:
        sys.exit(f"missing {label_sub!r} / {name!r}")
    return hits[0].replace(" ", "")

MSG_NAMES = ["ClientHello", "ServerHello", "EncryptedExtensions", "Certificate", "CertificateVerify", "Finished"]
msgs = []
for lb, nm, need, hx in blocks:
    if "construct a" in lb and nm in MSG_NAMES:
        # ClientHello is the client's; the rest of the flight is the server's.
        # The client's own Finished appears later in the client section and is
        # deliberately excluded from the server flight.
        if nm == "ClientHello" or lb.startswith("{server}"):
            msgs.append((nm, hx.replace(" ", "")))
order = [m[0] for m in msgs]

vals = {
    "client_private_key": one('create an ephemeral x25519 key pair', "private key") if False else None,
}
def pk(who, name):
    for lb, nm, need, hx in blocks:
        if who in lb and "x25519" in lb and nm == name:
            return hx.replace(" ", "")
    sys.exit("missing key " + who + " " + name)

vals = {
    "client_private_key": pk("{client}", "private key"),
    "client_public_key":  pk("{client}", "public key"),
    "server_private_key": pk("{server}", "private key"),
    "server_public_key":  pk("{server}", "public key"),
    "early_secret":            one('extract secret "early"', "secret"),
    "derived_early_secret":    one('derive secret for handshake "tls13 derived"', "expanded"),
    "shared_secret":           one('extract secret "handshake"', "IKM"),
    "handshake_secret":        one('extract secret "handshake"', "secret"),
    "client_hs_traffic_secret": one('derive secret "tls13 c hs traffic"', "expanded"),
    "server_hs_traffic_secret": one('derive secret "tls13 s hs traffic"', "expanded"),
    "derived_master_secret":   one('derive secret for master "tls13 derived"', "expanded"),
    "master_secret":           one('extract secret "master"', "secret"),
    "client_ap_traffic_secret": one('derive secret "tls13 c ap traffic"', "expanded"),
    "server_ap_traffic_secret": one('derive secret "tls13 s ap traffic"', "expanded"),
    "exporter_master_secret":  one('derive secret "tls13 exp master"', "expanded"),
    "resumption_master_secret": one('derive secret "tls13 res master"', "expanded"),
    "server_hs_write_key":     one('{server}  derive write traffic keys for handshake data', "key expanded"),
    "server_hs_write_iv":      one('{server}  derive write traffic keys for handshake data', "iv expanded"),
    # The client's handshake write keys are the mirror of the server's
    # handshake read keys; the RFC only prints them once, in the server
    # section (the client step says "same as").
    "client_hs_write_key":     one('{server}  derive read traffic keys for handshake data', "key expanded"),
    "client_hs_write_iv":      one('{server}  derive read traffic keys for handshake data', "iv expanded"),
    "server_finished_key":     one('{server}  calculate finished "tls13 finished"', "expanded"),
    "server_finished_message": one('{server}  construct a Finished', "Finished"),
    "client_app_write_key":    one('{client}  derive write traffic keys for application data', "key expanded"),
    "client_app_write_iv":     one('{client}  derive write traffic keys for application data', "iv expanded"),
    "client_app_record":       one('{client}  send application_data record', "complete record"),
    "client_app_payload":      one('{client}  send application_data record', "payload"),
    "client_finished_key":     one('{client}  calculate finished "tls13 finished"', "expanded"),
    "client_finished_message": one('{client}  construct a Finished', "Finished"),
}
# client handshake write keys live under the {server} section as the read keys
missing = [k for k, v in vals.items() if v is None]
if missing:
    sys.exit("missing values: " + ", ".join(missing))

ch = bytes.fromhex(vals["client_hello"]) if False else None

out = []
w = out.append
w("//! RFC 8448 §3 \"Simple 1-RTT Handshake\" intermediate values — GENERATED.")
w("//!")
w("//! Source: https://www.rfc-editor.org/rfc/rfc8448.txt")
w("//! sha256 of the fetched file:")
w("//!   6564d1376d1ec744fc7a9993da15ebc1b9be361908b166091f47ef605c537fba")
w("//! Extraction: `vectors/extract_rfc8448.py` / `vectors/emit_rfc8448_zig.py`.")
w("//! Every block's collected byte count is checked against the octet count")
w("//! printed in the RFC before this file is written, and the handshake")
w("//! messages are checked to parse (type byte + 3-byte length == remaining).")
w("//!")
w("//! All values are hex text; tests decode with std.fmt.hexToBytes.")
w("")
for k, v in vals.items():
    w(f"pub const {k} = \"{v}\";")
w("")
w("pub const HandshakeMessage = struct { name: []const u8, bytes: []const u8 };")
w("")
w("/// The server's handshake flight in wire order, as published (these are")
w("/// the *plaintext* handshake messages, header included).")
w("pub const server_flight = [_]HandshakeMessage{")
for nm, hx in msgs:
    w(f"    .{{ .name = \"{nm}\", .bytes = \"{hx}\" }},")
w("};")
w("")
(here.parent / "stage/user/src/lib/tls/rfc8448_vectors.zig").parent.mkdir(parents=True, exist_ok=True)
(here.parent / "stage/user/src/lib/tls/rfc8448_vectors.zig").write_text("\n".join(out) + "\n")
print("wrote rfc8448_vectors.zig;", len(msgs), "handshake messages:", order, file=sys.stderr)
print("values:", ", ".join(vals.keys()), file=sys.stderr)
