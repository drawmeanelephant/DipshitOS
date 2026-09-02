# Claim: Post-M35 — cross-language author proof: the virelai.zig shim + a rustc-authored app

- **Owner:** buffy2 (`agent/buffy2/m35-rust-author-proof`)
- **Prompt / plan:** `docs/march-m35-rust-author-proof.md` (this card's prompt/plan doc); tracker `docs/wasm-core-scoping.md` (post-M35 note)
- **Scope:** post-M35 hardening that makes the contract doc's **already-promised** cross-language authoring real: `docs/wasm-import-contract.md` §1 promises `virelai.zig` (the Zig sibling of `tests/virelai.h`) and §7 promises a `rustc --target wasm32-unknown-unknown` author path — neither exists yet. This claim (a) ships `tests/virelai.zig` (Zig extern decls mirroring `virelai.h`'s `env.*` imports, proven to compile a module whose import table is exactly the frozen surface), and (b) authors a **fresh Rust `wasm32-unknown-unknown` no_std app from the contract doc alone** — `tests/nl.rs`, a numbered-lines tool (`nl`/`cat -n` shape) reading `/host/WC.TXT` through `env.file_open/file_read/file_close` in 64-byte chunks, CRLF-tolerant, printing `%6d`-numbered lines byte-exact — pinned as `user/src/wasm-corpus/nl.wasm` and gated through the live boot (`tools/verify-live-wasm.sh` phase): byte-exact numbered lines + exit = output byte count + shell echo. Proves the contract is language-neutral (C via `zig cc`, Zig via `virelai.zig`, Rust via `rustc` — same frozen ABI, no WASI, no libc).
- **Touches:** tests/virelai.zig (new), tests/nl.rs (new), user/src/wasm-corpus/nl.wasm (new pinned binary), user/src/wasm.zig (host test: rustc-built fixture executes byte-exact through the capture seam + the overlong-LEB fix), tools/verify-live-wasm.sh (cross-language phase), docs/wasm-import-contract.md (§7 author recipes — virelai.zig + rustc — made real; C recipe corrected), docs/wasm-core-scoping.md (post-M35 note), claim + branch log; claim id via `bash tools/status/claim-id.sh`
- **Depends on:** W5 #766 (claim 5883, done — the capture-seam `file_data` simulation and the live-gate phase this rides on); W1a #778 contract
- **Heartbeat:** 2026-09-02
- **Status:** ✅ agent/buffy2/m35-rust-author-proof — DONE. Live class-B gate **PASS boot1 (rc=0)** with every needle green: all 8 nl needles byte-exact (numbered lines, exit 383, shell echo) and W2–W5 intact (floatapp 590, wc 320, fileapp 512, hello 55, winapp + red fill 10,436 px). The five-exec script1 + solo script3 phase design restored floatapp's exit-590 line lost to #803/#810 under six-exec contention; the kernel flake (#810, filed by another agent) is documented in the branch log. Evidence: artifacts/live-wasm-serial-boot1.log, live-wasm-report.txt, m35-wasm-live.txt.

## Notes

The rustc probe (a 55-byte-exit hello module built in /tmp during scoping)
already executed in the interpreter with ZERO interpreter changes — the
interpreter is language-agnostic; the only open question was authoring +
gating discipline, mirroring the W3–W5 fixture pattern (commit the pinned
binary, host-test it through the capture seam, sha-pin it in the live
gate). `nl` is deliberately NOT a second wc: it exercises the file channel
from Rust (byte-slice paths per §3, EOF-0 + cap-clamp per §5.1, negative
errno branching per §4) and prints clean distinct needles over the SAME
deterministic WC.TXT fixture (no new fixture file), with exit status = its
own output byte count (fileapp's length proof). Counts/output are
cross-validated against an independent Python reimplementation AND the
native cross-run harness before pinning.

Gate: `zig test user/src/wasm.zig` green (new exec test + all prior 39);
`zig build wasm` + bss budget; `tools/verify-live-wasm.sh` cross-language
phase PASS on VZ (numbered lines byte-exact + exit status + echo);
`verify-coordination` PASS. Milestone #22 is already 6/6 — this rides
post-M35 as contract-honoring hardening.

Claim id derivation: `bash tools/status/claim-id.sh "agent/buffy2/m35-rust-author-proof" "m35-rust-author-proof"` → **9746**. NOTE: `docs/status.md` is intentionally NOT touched by this branch — the driver of `agent/buffy/docs-pass` holds it (one editor per file); the post-M35 status prose for this claim is deferred to the merge, filed in the branch log.
