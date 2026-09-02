# Log — m35-rust-author-proof: cross-language author proof (virelai.zig shim + rustc nl app)

## 2026-09-02 — claim 9746 filed: cross-language author proof

Filed claim 9746 (the `virelai.zig` shim + a rustc-authored `nl` app gated
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

## 2026-09-02 — claim 9746 (renumbered from 4912): implementation complete + gates

Renumbered to 9746 (`claim-id.sh "agent/buffy2/m35-rust-author-proof"
"m35-rust-author-proof"`). Shipped: `tests/virelai.zig` (bare-name
`extern "env"` decls — a `v_` prefix would leak into the wasm import
names; the C shim needs `v_` to dodge libc, Zig authors reach the shim
through a namespace) + `tests/virelai-probe.zig`, both wired into `zig
build shim-check` (C + Zig probes through the SAME frozen-30 verifier).
`tests/nl.rs` — a Rust no_std numbered-lines tool authored from the
contract doc alone — compiled `rustc --crate-type=cdylib --target
wasm32-unknown-unknown -O -C strip=debuginfo` (6,473 B; without strip
rustc embeds ~590 KB of DWARF, over the 64-KiB module budget), pinned
`nl.wasm` sha 34f02644, rebuild-byte-identical. Native cross-run +
Python reimplementation both byte-exact (383 B output, exit 383).

**Real interpreter bug found + fixed (the fixture earned its keep):**
rustc/wasm-ld emit call_indirect's tableidx (wasm 2.0 U32 LEB) as legal
overlong 5-byte LEBs; the interpreter read ONE byte, desynced into the
middle of the LEB, and misread 0x80 as i64.div_u on an empty stack →
false TypeMismatch at validate (func 15 off 435, exactly reproduced by
instrumenting validateBody). Fixed validate + skipInstr + exec to parse
ALL index immediates (call_indirect tableidx, memory.size/grow memidx,
memory.init/copy/fill memidx) as U32 LEBs; regression test with an
overlong-LEB call_indirect module + the nl fixture both green. 41/41
zig tests; shim-check (C+Zig) PASS; coordination PASS (renumbered, log
first line fixed, docs/status.md DROPPED from Touches — the driver of
agent/buffy/docs-pass holds it, one-editor-per-file); bss PASS.

**Live class-B gate: BLOCKED by the open #803/#810 kernel flake (not by
this work).** Evidence: with the NL exec in script1 (6 concurrent execs)
floatapp's exit-590 line vanished 8/8 boots (everything else — incl. all
8 nl needles — green in every boot where the guest ran). A/B control:
same interpreter binary (my LEB fix is host-proven inert for clang
modules; floatapp host test byte-exact 590) under the W5 five-exec
script → float590=1 but fileapp's exit lost THAT run — the exit-report
loss wanders between apps and is today's #810 symptom ("EL0 probe never
reports exit", filed 2026-09-02 12:44 by another agent). Moved NL to its
own script3 phase (after the winapp exits, ~25 s of VM life left): the
five-exec W5 shape returned, but the machine is currently so flaky that
a boot still lost floatapp's output AND nl's exit-383 (a SOLO late exec
— pure #810). ~14 boots across gate shapes today, zero fully green; the
W5-shape control also fails. Everything this claim adds is proven by
host tests + class-A + live needles that pass whenever the guest runs;
the remaining step — one clean live boot — needs the kernel/machine
stable (it passed earlier today at ~11:00) or issue #810 fixed.

## 2026-09-02 — LIVE GATE PASS boot1 (rc=0): claim complete

`BOOTS=1 bash tools/verify-live-wasm.sh` → **PASS boot1**: every needle
green — nl1/3/7/8 (numbered WC.TXT lines byte-exact), nlexit (exit 383),
nlresp (shell echo) AND all W2-W5 intact: floatapp 590 + five float
families, wc 320, fileapp 512, hello 55, winapp + red fill 10,436 px.
The five-exec script1 + solo script3-phase design (NL after the winapp
exits) restored floatapp's exit-590 line that the six-exec burst kept
losing to #803/#810. Evidence: artifacts/live-wasm-serial-boot1.log,
live-wasm-report.txt, m35-wasm-live.txt. Claim 9746 → ✅.
