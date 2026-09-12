# Footnote — the wasm-channel framing of the spike (superseded, kept as evidence)

The spike originally asked whether a real Zig tool could run through the M35
wasm channel (`zig build-exe -target wasm32-freestanding → TOOL.WASM →
exec WASM.BIN TOOL.WASM`). That was measured first; the redirect moved the
target to the native ELF path. The numbers below are **not** the goal any
more — they are the record of what the channel does with a real tool.

## It compiles clean, and it is contract-clean

```bash
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fstrip \
    --dep virelai --dep oliver \
    -Mroot=tests/wasm-spike/tool.zig \
    -Mvirelai=tests/virelai.zig \
    -Moliver=tests/wasm-spike/oliver-src/oliver.zig \
    -femit-bin=tool.wasm
```

Compiled **first attempt, no error classes to report** — the frozen `env.*`
contract needed no shim change, no WASI, no new import:

| measurement | value |
|---|---|
| module size | 274,698 B |
| imports | `exit, file_close, file_open, file_read, write` — **the same five names as the W5 `wc` capstone**, module `env` only |
| declared memory | flags 0x0, min 23 pages (1472 KiB), no max → `validate()` sees 23 ≤ 32 |
| source | oliver `@3f05bacb`, its real `parse` + `html.render`, buffers static, allocator a `FixedBufferAllocator` |

`tests/wasm-spike/wasm-inspect.py` (spike tooling, **not** a gate) prints all
three checks; `python3 tools/verify-virelai-probe.py` covers the import-table
rule for the probe.

## Why it cannot run: one constant

`user/src/wasm.zig:3098` is `const max_module_size: usize = 64 * 1024;` and
the loader reads the module into `g_mod_buf: [max_module_size]u8`, failing with
`wasm: module too large` (exit 4) past that. The tool is **4.19× over**:

| build | size | vs 64 KiB |
|---|---|---|
| full tool (parse + render + file I/O) | 274,698 B | 4.19× |
| parse-only (`document` + `markdown`) | 171,463 B | 2.62× |
| render-only (`document` + `html`) — the floor for any HTML-emitting oliver app | 69,300 B | **1.06×** |

So no useful slice of this library fits, and the gap is a single userland
`.bss` buffer constant rather than the frozen contract. The 64 KiB budget is
deliberate (the image's comment: "Module ~77 KiB, Machine ~30 KiB, module
buffer 64 KiB" all in `.bss`), so raising it is a real decision, not a typo —
it is **not** part of this branch.

**Observed vs inferred:** the sizes, imports and memory declaration are
observed (module bytes + `tests/wasm-spike/wasm-inspect.py`). The rejection
itself is **inferred** from `max_module_size` and the `fail("wasm: module too
large", 4)` path in `user/src/wasm.zig`; the oversized module was never
executed live.

## Two smaller notes for the contract doc

* Contract §7's Zig recipe spells the output flag `-o app.wasm`; zig 0.16's
  `zig build-exe` rejects `-o` and wants `-femit-bin=app.wasm` (the repo's own
  `tools/build-zc-host.sh` already uses `-femit-bin=`). Not edited here — that
  file was declared only for a genuine clarification and this spike did not
  need one to proceed.
* `tests/wasm-spike/` keeps the slice source, the probes and the inspector so
  the measurement is reproducible; the 275 KiB module itself is not committed
  (rebuild with the line above).

Unrelated to this spike but hit while running the fleet — the AGENTS.md PATH
trap, stated precisely: in this shell `bash` resolved to **macOS `/bin/bash`
3.2.57**, and under `set -u` bash 3.2 treats the expansion of the *empty*
array `"${VGATE_NOTES[@]}"` (`tools/gate/vgate.sh:151`) as an unbound-variable
error, so the run died before the first boot. **Homebrew bash 5.3.15 passes the
same spec.** The gate script is not at fault and needs no change: the fix is
the documented one — `source tools/env-check.sh` in the session that runs
gates (or otherwise make `$HOMEBREW_BIN` lead `PATH` so `bash`/`sed` resolve to
the Homebrew builds) — and it must be sourced per session, since a subshell
cannot repair its parent's `PATH`.
