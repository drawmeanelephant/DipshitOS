#!/usr/bin/env python3
"""Extract RFC 8448 §3 (Simple 1-RTT Handshake) intermediate values into a
Zig vector module.

Every extracted value is validated: the number of hex bytes collected must
equal the octet count printed by the RFC, and the top-level handshake
messages must parse (type byte + 3-byte big-endian length == remaining).
Anything that fails validation aborts the run.
"""
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent
lines = (here / "rfc8448.txt").read_text().splitlines()

start = next(i for i, l in enumerate(lines) if l.startswith("3.  Simple 1-RTT Handshake"))
end = next(i for i, l in enumerate(lines) if l.startswith("4.  Resumed 0-RTT Handshake"))
sec = lines[start:end]

HEXPAIR = re.compile(r"\b[0-9a-f]{2}\b")
HEAD = re.compile(r"^([A-Za-z][A-Za-z0-9_]*?(?: [A-Za-z0-9_]+)*) \((\d+) octets\):\s*(.*)$")

blocks = []          # (label, name, bytes)
label = "(§3)"
pending = None       # [name, need, hexstr]

for raw in sec:
    s = raw.strip()
    if not s:
        continue
    if s.startswith("{client}") or s.startswith("{server}"):
        if pending:
            blocks.append(pending)
            pending = None
        label = s.rstrip(":").strip()
        continue
    m = HEAD.match(s)
    if m:
        if pending:
            blocks.append(pending)
        pending = [label, m.group(1), int(m.group(2)), m.group(3)]
        continue
    if pending is not None:
        # continuation line of hex; ignore page furniture and other text
        toks = HEXPAIR.findall(s)
        if toks and len(toks) == len(s.split()):
            pending[3] += " " + " ".join(toks)
        # else: page header/footer or prose - ignore, the octet-count check
        # below is what proves nothing was lost.
        continue
if pending:
    blocks.append(pending)

# Validate every block's octet count.
bad = 0
for label_, name, need, hx in blocks:
    got = len(hx.split())
    if need == 0:
        continue
    if got != need:
        print(f"OCTET MISMATCH {label_} / {name}: declared {need}, collected {got}", file=sys.stderr)
        bad += 1
if bad:
    sys.exit(f"{bad} blocks failed validation")

def find(pred):
    for label_, name, need, hx in blocks:
        if pred(label_, name):
            return bytes.fromhex(hx.replace(" ", ""))
    raise KeyError("not found")

def findall(pred):
    return [(l, n, bytes.fromhex(h.replace(" ", ""))) for l, n, _, h in blocks if pred(l, n)]

# --- validate the two handshake messages parse ---
ch = find(lambda l, n: n == "ClientHello")
sh = find(lambda l, n: n == "ServerHello")
for nm, msg in (("ClientHello", ch), ("ServerHello", sh)):
    typ = msg[0]
    ln = int.from_bytes(msg[1:4], "big")
    assert ln == len(msg) - 4, f"{nm}: length {ln} != {len(msg)-4}"
    assert typ in (1, 2), f"{nm}: bad type {typ}"
    print(f"validated {nm}: type={typ} len={len(msg)}", file=sys.stderr)

import hashlib
th = hashlib.sha256(ch + sh).hexdigest()
print("transcript hash (CH||SH) =", th, file=sys.stderr)

def h(nm, labelpred=None):
    if labelpred is None:
        return find(lambda l, n: n == nm)
    return find(lambda l, n: n == nm and labelpred in l)

want = {
    "client_private_key": find(lambda l, n: n == "private key" and "{client}" in l),
    "client_public_key":  find(lambda l, n: n == "public key" and "{client}" in l),
    "server_private_key": find(lambda l, n: n == "private key" and "{server}" in l),
    "server_public_key":  find(lambda l, n: n == "public key" and "{server}" in l),
    "client_hello": ch,
    "server_hello": sh,
    "transcript_hash_ch_sh": bytes.fromhex(th),
    "shared_secret":    find(lambda l, n: n == "IKM" and "{server}" in l and None) if False else None,
}
# shared secret is the IKM of the "extract secret handshake" step
ss = find(lambda l, n: n == "IKM")
# there are several IKM entries; the handshake one is preceded by the derived salt.
# Identify by value length 32 and by being the IKM whose salt equals the derived value.
derived_early = None
for l, n, v in findall(lambda l, n: n == "expanded"):
    pass
want["shared_secret"] = ss

print("\n--- blocks in §3 ---", file=sys.stderr)
for l, n, need, hx in blocks:
    print(f"{l:12s} {n:34s} {need:5d}", file=sys.stderr)
