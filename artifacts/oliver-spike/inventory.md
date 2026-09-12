# Phase 1 — oliver dependency inventory (before compiling)

Reference tool: `/Users/tbuddy/t3/zig/oliver` (the only reference project in
scope; the two converter projects are **deferred** and were neither
inventoried nor compiled).

* **Version pin:** `build.zig.zon` → `minimum_zig_version = "0.16.0"`; the repo
  is also pinned at `.zigversion` **0.16.0** → **no version mismatch**.
* **Commit:** `3f05bacb188ab28ad797430c82d9ee20080c5ed6` (2026-08-27), working
  tree clean at inventory time.
* **Third-party dependencies:** `dependencies = .{}` — **zero** packages.
* **Size:** 23 `src/*.zig` files, 30,022 lines. Largest: `markdown.zig` 7,891,
  `textile.zig` 5,899, `entities.zig` 2,319, `html.zig` 2,162, `unicode.zig`
  1,344.
* **Shape:** the library root is `src/oliver.zig` (271 lines). It exposes
  `parse(allocator, bytes, dialect, options) → ParseResult` and
  `html.render(allocator, *std.Io.Writer, *const Document, options)`. A
  provisional CLI (`src/main.zig`, 1,876 lines) is stdin → stdout; the
  C ABI (`src/c_abi.zig`) and the Cooklang modules are exported/forced by a
  `comptime { _ = … }` block in the root.

## std surface (grep counts over `src/*.zig`)

| std area | uses | class | why |
|---|---|---|---|
| `std.ArrayList` (176), `std.StringHashMap` (11), `std.mem.*` | ~900 | **(a) pure compute** | parser/renderer internals; work on a caller-supplied allocator |
| `std.fmt.*` (24+15+6) | 45 | **(a) pure compute** | HTML/attribute formatting, number parsing |
| `std.Io.Writer.Allocating` (92) | 92 | **(c) allocator** | render target in the CLI; the library itself takes `anytype` writer |
| `std.heap.ArenaAllocator.init` (21) | 21 | **(c) allocator** | the document owns one arena; `deinit` is one step |
| `std.Io.Dir.cwd` (23), `std.fs.path.*` (24), `std.process.Init` (3), `std.Io.Threaded.init` (5) | 55 | **(b) file I/O — CLI only** | confined to `src/main.zig`, `src/manifest.zig`, `src/plan.zig` |
| `std.debug.print/assert` | 21 | **(a)** | diagnostics; `assert` is compile-time/`ReleaseSmall`-inert |
| `std.json.Stringify` (3) | 3 | **(a)** | CLI `--diagnostics` output only |
| `std.testing.*` | ~1,400 | **(a), tests only** | not linked into an app build |
| `std.Thread` / `std.net` / `std.time` | **0** | — | the tool has no threads, no network, no clock |

`src/oliver.zig`'s own header states the property this inventory confirms:
*"The parser never reads files or the environment… The renderer writes to any
writer and never reparses… No global state, no hidden caches, deterministic
output. … Only the CLI (src/main.zig) touches stdio."* A grep for
`std.Io.Dir` / `std.fs.path` / `std.process` / `std.Io.Threaded` over `src/`
matches exactly three files — `main.zig`, `manifest.zig`, `plan.zig` — all in
the publication/CLI layer, none in the Markdown → HTML path.

## Other risk dimensions

* **comptime / metaprogramming:** no build-time code generation. The
  entity/Unicode tables are checked-in Zig source; `tools/gen-entities.py` and
  `tools/gen-unicode.py` regenerate them offline and are not part of a build.
* **libc interop:** none. `c_abi.zig` *exports* a C ABI for embedders; it does
  not call libc.
* **argv/env:** the library takes a byte slice; only the CLI parses argv.
* **Subprocess / usermode shell-outs:** none (no `std.process.Child`).
* **Clock / time:** none in the library path.

## Gap estimate table (written before the first compile)

| # | dependency | class | estimated gap to the guest | outcome |
|---|---|---|---|---|
| 1 | Markdown/Textile frontends + HTML renderer (`document`, `markdown`, `html`, `entities`, `unicode`) | (a) pure compute | none expected — no host calls | **confirmed**: compiled as-is, both targets |
| 2 | Library allocator requirement | (c) allocator | `env.mmap` (wasm §5.5) / anonymous `sys_mmap` slot 63 + a std heap shim | **confirmed**: `ArenaAllocator` over `FixedBufferAllocator` on an mmap'd region; no shim change |
| 3 | Input/output | (b) file I/O | contract §5.1 (wasm) / ADR 0010 file table + M34 HF share (native) | **confirmed**: read `/host/MD.TXT`, wrote `/host/OLIVER.HTML` |
| 4 | CLI argv (`oliver render --from …`) | (b) + entry contract | `_start(argc, argv)` exists, but see the gap report — raw ELF images get `.no_args_room` | **partially blocked** (loader, #1163) |
| 5 | WASI / libc / threads / clock / network | (d) hard | none — the tool has none of these in the HTML path | **no blockers of this class exist** |

The pre-compile estimate was therefore "expected to compile with shim-level
work only, and the only unknown is *delivery* (module/loader budget)" — which
is exactly what the two measured attempts found: the wasm channel was over its
64 KiB module budget, and the native path fits at 95% of the 256 KiB cap.
