# wasm-spike — footnote: oliver through the M35 wasm channel

The spike's original framing (a real Zig tool via `exec WASM.BIN TOOL.WASM`)
was measured here and then superseded by the native ELF path
(`tests/oliver-spike/`, gate `tools/gate/specs/live-oliver.spec`). The result
and the full numbers live in
`artifacts/wasm-zigtool-spike/wasm-footnote.md`: the tool builds
contract-clean (imports exactly the frozen `env.*` five, 23/32 memory pages)
but is 274,698 B against the interpreter's 64 KiB `max_module_size`
(`user/src/wasm.zig:3098`), 4.19× over, with no useful slice below the cap
(the renderer-only floor is 69,300 B).

Kept because it is the reproducible measurement, not a shipped app:

| file | what it is |
|---|---|
| `tool.zig` | the slice: oliver's real `parse` + `html.render` behind the `virelai.zig` shim, reading `/host/MD.TXT` and writing to fd 1 |
| `sizeprobe_parse_only.zig`, `sizeprobe_render_only.zig` | the size-ladder probes |
| `wasm-inspect.py` | spike tooling (NOT a gate): module size, import table, memory limits vs the interpreter's caps |

Build (after copying oliver's `src/` to `tests/wasm-spike/oliver-src/` as
untracked input):

```bash
zig build-exe -target wasm32-freestanding -O ReleaseSmall -fstrip \
    --dep virelai --dep oliver \
    -Mroot=tests/wasm-spike/tool.zig \
    -Mvirelai=tests/virelai.zig \
    -Moliver=tests/wasm-spike/oliver-src/oliver.zig \
    -femit-bin=tool.wasm
python3 tests/wasm-spike/wasm-inspect.py tool.wasm
```

The input fixture and the reference HTML are shared with the native slice:
`tests/oliver-spike/md-fixture.txt`, `tests/oliver-spike/expect.html`.
