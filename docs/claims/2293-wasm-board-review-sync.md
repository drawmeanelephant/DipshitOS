# Claim: WASM milestone review sync — W1a/W1b split + W2–W5 tightening

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** Adjudicate the second review pass (M35 WASM board) and apply the real findings to the issue bodies + scoping doc: split W1 into W1a (contract freeze, #778) + W1b (interpreter, #762), freeze the memory bound (2 MiB/32 pages), defer Go to post-M35 (option b), fix the W5 capstone as `wc`, tie W4 floats to a named program, name the contract artifact, defer the `wasm run` monitor command, add BSS/corpus hygiene to W1b.
- **Scope:** GitHub issue edits + doc-only repo changes (`docs/wasm-core-scoping.md`, `docs/line-of-sight.md` W-row) — no kernel/userland code. Selectively ignored: the reviewer's status.md claim (stale — M32/M33/M34 rows exist on main) and the `--cvc-file` blocking worry (moot — HF4 landed, share is stable).
- **Touches:** docs/wasm-core-scoping.md docs/line-of-sight.md docs/claims/2293-wasm-board-review-sync.md docs/logs/freebuff-20260901-002.md
- **Depends on:** M35 issues #762–#766 filed (claim 3904); HF4 merged (PR #769); the self-hosting review pass (claim 1263, PR #777)
- **Heartbeat:** 2026-09-01
- **Status:** 🔄 in progress

## Notes

Facts verified before editing: W1–W5 Touches all declare `user/src/wasm.zig` (except W5 — capstone app + docs) → interpreter lane is strictly linear after W1b; build.zig has zero wasm refs (path is free to freeze as `user/src/wasm.zig`); PR #772 (other agent) touches kernel/user files only — no docs overlap. Issue edits: created #778 (W1a), re-scoped #762 (W1b), updated #763–#766 bodies.
