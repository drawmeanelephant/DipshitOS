# Claim: M35 seed — WASM scoping doc + line-of-sight tracker

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** `docs/wasm-core-scoping.md` (M35 W1–W5 gated card split) + `docs/line-of-sight.md` (board mirror)
- **Scope:** Post-M34 planning only — no kernel/userland code. Author the M35 WASM-core-interpreter scoping seed (one bounded wasm-core interpreter in Zig, `WASM.BIN`, modules as data via the M34 file channel, custom `env.*` imports mapped to ADR 0007 — no WASI, zero new syscall slots), file it as issues W1–W5 (#762–#766) under a new M35 milestone (#22) + `m35-wasm` label per the HF1–HF7 precedent, re-scope the self-hosting compiler thread (#708 → Z0.5+VL6), file the zc ladder Z0.5–Z4b (#749–#761) under milestone #20, and land the line-of-sight tracker.
- **Touches:** docs/wasm-core-scoping.md docs/line-of-sight.md docs/claims/3904-wasm-line-of-sight-docs.md docs/logs/freebuff-20260901-001.md
- **Depends on:** M34 HF1–HF3 merged (claims 7710/9459); the zc compiler spine (claim 0098); current `origin/main`
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

Doc-only planning half. Verified against current trunk before filing: the
guest ELF loader (`kernel/src/elf.zig`) is class-agnostic (accepts ELF32 and
ELF64 — `ei_class` 1 or 2), `mkdyn-elf.py` already emits ELF64 `.SO` files,
and host `zig cc -target wasm32-freestanding -nostdlib` produces a 684-byte
wasm module — the facts that make the WASM pitch concrete (module = data,
no ELF contract). Filed: milestone #22 + `m35-wasm` label, issues #762–#766
(W1–W5), #749–#761 (zc ladder), #708 re-scoped to Z0.5+VL6, and
`docs/line-of-sight.md` as the board mirror.
