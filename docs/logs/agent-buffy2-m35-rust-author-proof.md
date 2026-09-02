# Branch log — agent/buffy2/m35-rust-author-proof

## 2026-09-02 — claim 4912 filed: cross-language author proof

Filed claim 4912 (the `virelai.zig` shim + a rustc-authored `nl` app gated
through the live boot). Motivation: the contract doc already promises both
`tests/virelai.zig` (§1 host-shims note) and the `rustc
--target wasm32-unknown-unknown` author path (§7) — neither exists; this
claim makes those promises real and extends W5's standalone-author
provenance proof to a second language, proving the frozen ABI is
language-neutral.

Branch cut at the W5 tip (7e33dfa) — the W4+W5 body (PR #813) rides a
separate branch; this branch needs the W5 capture-seam `file_data`
simulation + the live-gate fixture pattern, so it bases off the W5 tip.

Scoping probes completed before filing: (1) a rustc-built hello module
(`#![no_std]`, `#[link(wasm_import_module = "env")]`, exports `_start`,
55-byte exit) executed in the interpreter with zero interpreter changes —
parse → validate → instantiate → exec, byte-exact; (2) rustc wasm output
validates cleanly (memory 17 pages, `__data_end`/`__heap_base` global
exports accepted). A scratch probe-removal slip duplicated a 352-line test
block in `user/src/wasm.zig`; restored the file to the committed W5 state
(`git checkout`), re-verified 39/39 — tree clean at filing time.
