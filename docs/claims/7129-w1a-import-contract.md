# Claim: W1a import contract freeze — docs/wasm-import-contract.md (#778)

- **Owner:** t3code (`t3code/1145c9b5`)
- **Prompt / plan:** `docs/wasm-core-scoping.md` (M35 WASM board, W1a #778)
- **Scope:** the contract doc + the scoping-doc pointer. Out: all interpreter code (W1b), import implementation (W3), floats (W4), the capstone app (W5), WASI itself.
- **Touches:** docs/wasm-import-contract.md (new), docs/wasm-core-scoping.md (pointer), docs/claims/7129-w1a-import-contract.md, docs/logs/t3code-1145c9b5.md
- **Depends on:** none — claimable now, in parallel with W1b (#762)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

Frozen contract: `docs/wasm-import-contract.md` — the `env.*` → ADR 0007 mapping table (file 23–27 + 34–37, win 12–20, audio 42–45, timers 40/41, mmap 63, procs 7, wait 8), argument shapes and error mapping per import, and the three decisions pinned there: Go wasm deferred to post-M35 (option b), linear memory capped at 2 MiB / 32 pages with a `memory.grow` trap, and the W5 capstone = `wc`. W3 (#764) and W5 (#766) bodies point at it. Docs-only, default boots byte-identical.

Gate: the contract doc is checked in and reviewed; a fresh host author could implement any listed import from the doc alone; W3/W5 bodies reference it.
