#!/usr/bin/env python3
#
# wasm-manifest.py -- contract v2 (docs/wasm-import-contract.md §9) delivery
# tooling for wasm modules: stamp the `virelai.abi` custom section, and
# generate / verify the host-share manifest (`/host/WASM.TXT`) the guest
# admits modules against.
#
#   stamp <file.wasm> <section-text>   add or REPLACE the section (idempotent)
#   gen   <share-dir>                  write WASM.TXT for the v2 modules found
#   check <share-dir>                  re-verify every row against every file
#
# The name->capability mapping is READ OUT OF user/src/wasm.zig (the
# `frozen_imports` table), never duplicated here: the tool and the loader
# cannot disagree about which capability owns an import. §9 is the format's
# authority; this file is the mechanism.
#
# `gen` writes a row ONLY for modules that declare `virelai.abi` (contract
# v2), because those are the only deliveries the guest admits: a v1 module has
# no section, is not admitted, and keeps the legacy drop-and-exec path. v1
# modules found in the directory are reported on stderr, not written.
#
# Exit status: 0 ok, 1 a check/verification failure, 2 usage or malformed input.

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WASM_ZIG = ROOT / "user" / "src" / "wasm.zig"
ABI_SECTION = b"virelai.abi"
CURRENT_REVISION = 2
MANIFEST_NAME = "WASM.TXT"


def fail(msg):
    print(f"wasm-manifest: {msg}", file=sys.stderr)
    raise SystemExit(1)


def usage():
    print(__doc__.strip(), file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------
# The capability table, read from the loader's own source of truth.
# --------------------------------------------------------------------------
def cap_table():
    try:
        src = WASM_ZIG.read_text()
    except OSError as exc:
        fail(f"cannot read {WASM_ZIG}: {exc}")
    block = re.search(r"const frozen_imports = \[_\]Frozen\{(.*?)\n\};", src, re.S)
    if not block:
        fail(f"cannot find the frozen_imports table in {WASM_ZIG}")
    table = {}
    for line in block.group(1).splitlines():
        name = re.search(r'\.name = "([^"]+)"', line)
        cap = re.search(r"\.cap = \.(\w+)", line)
        if name and cap:
            table[name.group(1)] = cap.group(1)
    if not table:
        fail("the frozen_imports table parsed as empty")
    return table


# --------------------------------------------------------------------------
# Minimal wasm reader: enough for the import list and custom sections.
# --------------------------------------------------------------------------
def uleb(buf, i):
    """Return (value, next_index) or raise ValueError."""
    val = 0
    shift = 0
    while True:
        if i >= len(buf):
            raise ValueError("truncated LEB128")
        byte = buf[i]
        i += 1
        val |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return val, i
        shift += 7
        if shift > 63:
            raise ValueError("LEB128 too long")


def sections(buf):
    if len(buf) < 8 or buf[:4] != b"\x00asm" or buf[4:8] != b"\x01\x00\x00\x00":
        raise ValueError("not a wasm 1.0 module")
    i = 8
    while i < len(buf):
        sid = buf[i]
        i += 1
        size, i = uleb(buf, i)
        if i + size > len(buf):
            raise ValueError("truncated section payload")
        yield sid, buf[i : i + size]
        i += size


def parse_module(buf):
    """Return (imports, abi_text) where imports is a list of import names."""
    imports = []
    abi_text = None
    for sid, payload in sections(buf):
        if sid == 0:
            nlen, j = uleb(payload, 0)
            if j + nlen > len(payload):
                continue
            if payload[j : j + nlen] == ABI_SECTION:
                abi_text = payload[j + nlen :].decode("ascii", "replace")
        elif sid == 2:
            count, j = uleb(payload, 0)
            for _ in range(count):
                mlen, j = uleb(payload, j)
                j += mlen  # module name; §1 allows only "env", the guest checks
                flen, j = uleb(payload, j)
                imports.append(payload[j : j + flen].decode("ascii", "replace"))
                j += flen
                kind = payload[j]
                j += 1
                if kind == 0:  # func: type index
                    _, j = uleb(payload, j)
                elif kind == 1:  # table: elemtype + limits
                    j += 1
                    _, j = uleb(payload, j)
                    _, j = uleb(payload, j)
                elif kind == 2:  # memory: limits
                    _, j = uleb(payload, j)
                    _, j = uleb(payload, j)
                elif kind == 3:  # global: valtype + mutability
                    j += 2
                else:
                    raise ValueError("unknown import kind")
    return imports, abi_text


def parse_abi_text(text, where):
    """§9.1, strictly. Returns (revision, caps set)."""
    revision = None
    caps = set()
    for raw in text.split("\n"):
        line = raw.strip(" \t\r")
        if not line or line.startswith("#"):
            continue
        if line.startswith("virelai.abi="):
            if revision is not None:
                raise ValueError(f"{where}: duplicate virelai.abi directive")
            value = line[len("virelai.abi=") :]
            if not value.isdigit():
                raise ValueError(f"{where}: `{value}` is not a revision")
            revision = int(value)
        elif line.startswith("capabilities="):
            names = line[len("capabilities=") :]
            if not names:
                raise ValueError(f"{where}: empty capability list (omit the line)")
            for name in names.split(","):
                caps.add(name)
        else:
            raise ValueError(f"{where}: unknown directive `{line}`")
    if revision is None:
        raise ValueError(f"{where}: virelai.abi=<n> is required")
    if revision < 1 or revision > CURRENT_REVISION:
        raise ValueError(f"{where}: unsupported revision {revision}")
    return revision, caps


def describe(path):
    """(size, sha256hex, revision, used caps, declared caps) or None for v1."""
    buf = path.read_bytes()
    imports, abi_text = parse_module(buf)
    if abi_text is None:
        return None
    table = cap_table()
    revision, declared = parse_abi_text(abi_text, path.name)
    unknown = declared - set(table.values())
    if unknown:
        raise ValueError(f"{path.name}: unknown capability {sorted(unknown)}")
    used = {table[name] for name in imports if name in table}
    return (
        len(buf),
        hashlib.sha256(buf).hexdigest(),
        revision,
        used,
        declared,
    )


def row_for(path):
    info = describe(path)
    if info is None:
        return None
    size, digest, revision, used, _declared = info
    caps = ",".join(sorted(used)) if used else "none"
    return f"{path.name.upper()} | {size} | {digest} | abi={revision} | caps={caps}"


def modules_in(share):
    found = sorted(
        p for p in share.iterdir() if p.is_file() and p.suffix.lower() == ".wasm"
    )
    if not found:
        fail(f"no .wasm modules in {share}")
    return found


def cmd_stamp(argv):
    if len(argv) != 2:
        usage()
    path, text = Path(argv[0]), argv[1]
    # `\n` in the argument is the two-character escape; the section payload is
    # line-oriented, so accepting it is what makes a one-line shell invocation
    # possible (see §9.2's authoring example).
    text = text.replace("\\n", "\n")
    buf = path.read_bytes()
    # Drop any existing section first, so re-stamping is idempotent.
    out = bytearray(buf[:8])
    removed = 0
    for sid, payload in sections(buf):
        if sid == 0:
            nlen, j = uleb(payload, 0)
            if payload[j : j + nlen] == ABI_SECTION:
                removed += 1
                continue
        out.append(sid)
        out += uleb_bytes(len(payload))
        out += payload
    payload = uleb_bytes(len(ABI_SECTION)) + ABI_SECTION + text.encode("ascii")
    section = bytes([0]) + uleb_bytes(len(payload)) + payload
    path.write_bytes(bytes(out[:8]) + section + bytes(out[8:]))
    print(
        f"wasm-manifest: stamped {path.name} (abi section "
        f"{'replaced' if removed else 'added'}, {len(text)} B payload)"
    )


def uleb_bytes(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def cmd_gen(argv):
    if len(argv) != 1:
        usage()
    share = Path(argv[0])
    rows = []
    skipped = []
    for path in modules_in(share):
        try:
            row = row_for(path)
        except ValueError as exc:
            fail(str(exc))
        if row is None:
            skipped.append(path.name)
        else:
            rows.append(row)
    manifest = share / MANIFEST_NAME
    body = [
        "# Contract v2 delivery manifest (docs/wasm-import-contract.md §9.2).",
        "# Generated by tools/wasm-manifest.py gen — do not hand-edit.",
        "# NAME.WASM | bytes | sha256 | abi=<n> | caps=<used>",
    ]
    body += rows if rows else ["# (no v2 modules in this share)"]
    manifest.write_text("\n".join(body) + "\n")
    print(
        f"wasm-manifest: {manifest} written with {len(rows)} row(s)"
        + (f"; v1 (not admitted): {', '.join(skipped)}" if skipped else "")
    )
    if not rows:
        print("wasm-manifest: warning: no v2 module rows — a v2 module here would be refused")


def cmd_check(argv):
    if len(argv) != 1:
        usage()
    share = Path(argv[0])
    manifest = share / MANIFEST_NAME
    if not manifest.exists():
        fail(f"{manifest} does not exist (run `gen` first)")
    listed = {}
    for raw in manifest.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) != 5:
            fail(f"{manifest}: row is not five fields: {line}")
        listed[fields[0]] = fields[1:]
    failures = []
    for path in modules_in(share):
        try:
            row = row_for(path)
        except ValueError as exc:
            fail(str(exc))
        key = path.name.upper()
        if row is None:
            # A v1 module is not admitted, so it needs no row; a row for it
            # would be a stale claim about a delivery that is not vouched for.
            if key in listed:
                failures.append(f"{path.name}: v1 module (no virelai.abi) yet listed")
                listed.pop(key)
            continue
        fields = [f.strip() for f in row.split("|", 1)[1].split("|")]
        have = listed.get(key)
        if have is None:
            failures.append(f"{path.name}: v2 module with no manifest row")
            continue
        if have != fields:
            failures.append(
                f"{path.name}: row mismatch\n    manifest: {have}\n    actual:   {fields}"
            )
        listed.pop(key)
    for orphan in listed:
        failures.append(f"{orphan}: listed but not present in the share")
    if failures:
        for f in failures:
            print(f"wasm-manifest: FAIL {f}", file=sys.stderr)
        raise SystemExit(1)
    print("wasm-manifest: check OK — every v2 row matches its file byte-for-byte")


def main(argv):
    if not argv:
        usage()
    cmd, rest = argv[0], argv[1:]
    if cmd == "stamp":
        cmd_stamp(rest)
    elif cmd == "gen":
        cmd_gen(rest)
    elif cmd == "check":
        cmd_check(rest)
    else:
        usage()


if __name__ == "__main__":
    main(sys.argv[1:])
