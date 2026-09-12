#!/usr/bin/env python3
"""wasm-inspect.py — spike-local inspector for a candidate wasm tool module.

NOT a gate (GF6: gates are declarative specs under tools/gate/specs/). This
is spike tooling: it reports the three things the M35 wasm channel measures a
module against, straight from the binary:

  1. module size vs the interpreter's `max_module_size` (64 KiB, user/src/wasm.zig)
  2. the import table vs the frozen `env.*` surface (docs/wasm-import-contract.md §5)
  3. declared linear-memory limits vs the 32-page / 2 MiB cap (contract §2 D2,
     enforced at validate(): `mem_max_pages > max_mem_pages -> MemoryTooBig`,
     and `mem_min_pages` must fit under the same 32 pages)

Usage: python3 tests/wasm-spike/wasm-inspect.py <module.wasm>
Exit 0 = inside every cap and env.*-only; non-zero otherwise.
"""

import sys

MAX_MODULE_SIZE = 64 * 1024
MAX_MEM_PAGES = 32

FROZEN = {
    "write", "exit",
    "file_open", "file_read", "file_write", "file_close", "dir_list",
    "file_delete", "file_rename", "file_truncate", "file_free",
    "win_open", "win_fill", "win_present", "win_close", "win_move",
    "win_raise", "win_get", "win_query", "win_set_visible",
    "audio_info", "audio_play", "audio_volume", "audio_mute",
    "timer_set", "timer_cancel",
    "mmap", "munmap",
    "procs", "wait",
}


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


def inspect(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x00asm\x01\x00\x00\x00":
        raise SystemExit(f"FAIL: not a wasm module: {path}")
    p = 8
    imports = []
    memories = []
    while p < len(data):
        sid, p = leb(data, p)
        if sid == 0:  # custom section
            sz, p = leb(data, p)
            p += sz
            continue
        sz, p = leb(data, p)
        end = p + sz
        if sid == 2:  # import
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
                if kind == 0x02:  # memtype import
                    flags, q = leb(data, q)
                    mn_pages, q = leb(data, q)
                    if flags & 0x01:
                        _, q = leb(data, q)
                    imports.append((module, name, "memory"))
                    continue
                _, q = leb(data, q)  # type index
                imports.append((module, name, "func"))
        elif sid == 5:  # memory
            cnt, q = leb(data, p)
            for _ in range(cnt):
                flags, q = leb(data, q)
                mn, q = leb(data, q)
                mx = None
                if flags & 0x01:
                    mx, q = leb(data, q)
                memories.append((flags, mn, mx))
        p = end
    return data, imports, memories


def main():
    if len(sys.argv) != 2:
        print("usage: wasm-inspect.py <module.wasm>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    data, imports, memories = inspect(path)
    ok = True

    print(f"module: {path}")
    print(f"  size: {len(data)} B (cap {MAX_MODULE_SIZE} B / 64 KiB)")
    if len(data) > MAX_MODULE_SIZE:
        print("  FAIL: module exceeds the interpreter's max_module_size (wasm: module too large, exit 4)")
        ok = False

    foreign = [(m, n) for m, n, _ in imports if m != "env"]
    funcs = [n for m, n, k in imports if k == "func"]
    unknown = sorted(set(funcs) - FROZEN)
    print(f"  imports: {len(funcs)} function(s), modules={sorted({m for m, _, _ in imports})}")
    if foreign:
        print(f"  FAIL: non-env import modules: {foreign}")
        ok = False
    if unknown:
        print(f"  FAIL: imports outside the frozen §5 surface: {unknown}")
        ok = False
    if not unknown and not foreign:
        print(f"  env.* names: {sorted(funcs)}")

    if not memories:
        print("  memory: none declared")
    for flags, mn, mx in memories:
        eff = mx if mx is not None else mn
        print(f"  memory: flags=0x{flags:x} min={mn} pages max={'none' if mx is None else mx} pages")
        print(f"    contract D2 requires max(declared) <= {MAX_MEM_PAGES} pages; "
              f"effective max used by validate() = {eff} pages "
              f"({eff * 64} KiB)")
        if eff > MAX_MEM_PAGES:
            print("    FAIL: declared max pages > 32 -> validate() MemoryTooBig "
                  "(guest reports 'wasm: validate error', exit 11)")
            ok = False
        if mn > MAX_MEM_PAGES:
            print("    FAIL: declared min pages > 32 -> validate() MemoryTooBig "
                  "(guest reports 'wasm: validate error', exit 11)")
            ok = False

    print("PASS: inside every interpreter cap, env.* only" if ok else "FAIL: see above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
