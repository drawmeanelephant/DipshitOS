#!/usr/bin/env python3
"""verify-virelai-probe.py — class-A check for the W3 shim acceptance item.

Parses the import section of a wasm32 module (the compiled
tests/virelai-probe.c) and asserts the import table is EXACTLY the frozen
`env.*` surface from docs/wasm-import-contract.md (W1a #778) + the W2
write/exit pair — the same 30 names the interpreter's validator and
dispatch implement.

Usage: python3 tools/verify-virelai-probe.py <module.wasm>
Exit 0 = exact match; non-zero with a diff listing otherwise.
"""

import sys


def leb(data, p):
    v = 0
    shift = 0
    while True:
        b = data[p]
        p += 1
        v |= (b & 0x7F) << shift
        if not (b & 0x80):
            return v, p
        shift += 7


FROZEN = [
    "write", "exit",
    "file_open", "file_read", "file_write", "file_close", "dir_list",
    "file_delete", "file_rename", "file_truncate", "file_free",
    "win_open", "win_fill", "win_present", "win_close", "win_move",
    "win_raise", "win_get", "win_query", "win_set_visible",
    "audio_info", "audio_play", "audio_volume", "audio_mute",
    "timer_set", "timer_cancel",
    "mmap", "munmap",
    "procs", "wait",
]


def main():
    if len(sys.argv) != 2:
        print("usage: verify-virelai-probe.py <module.wasm>", file=sys.stderr)
        return 2
    data = open(sys.argv[1], "rb").read()
    if data[:8] != b"\x00asm\x01\x00\x00\x00":
        print("FAIL: not a wasm module", file=sys.stderr)
        return 1
    p = 8
    imports = []
    while p < len(data):
        sid, p = leb(data, p)
        if sid == 0:  # custom section: skip payload
            sz, p = leb(data, p)
            p += sz
            continue
        sz, p = leb(data, p)
        payload_end = p + sz
        if sid == 2:
            cnt, q = leb(data, p)
            for _ in range(cnt):
                mn, q = leb(data, q)
                module = data[q:q + mn].decode()
                q += mn
                nn, q = leb(data, q)
                name = data[q:q + nn].decode()
                q += nn
                kind = data[q]
                q += 1
                _, q = leb(data, q)  # type index
                imports.append((module, name, kind))
        p = payload_end
    got = [n for m, n, k in imports if k == 0]
    if any(m != "env" for m, _, _ in imports):
        print(f"FAIL: foreign import modules: {[(m, n) for m, n, _ in imports if m != 'env']}", file=sys.stderr)
        return 1
    if len(got) != len(FROZEN) or sorted(got) != sorted(FROZEN):
        print("FAIL: probe import table != frozen surface (set difference)", file=sys.stderr)
        print(f"  missing: {sorted(set(FROZEN) - set(got))}", file=sys.stderr)
        print(f"  extra:   {sorted(set(got) - set(FROZEN))}", file=sys.stderr)
        print(f"  got {len(got)} imports: {sorted(got)}", file=sys.stderr)
        return 1
    print(f"ok: virelai-probe imports exactly the frozen {len(FROZEN)} env.* surface (order is linker-defined)")
    return 0


if __name__ == "__main__":
    sys.exit(main())