# Claim: M35 W5 — the ecosystem capstone: wc (issue #766)

- **Owner:** buffy2 (`agent/buffy2/m35-w5-wc-capstone`)
- **Prompt / plan:** `docs/march-m35-w5-wc-capstone.md` (this card's prompt/plan doc); tracker `docs/wasm-core-scoping.md` (card table); issue #766 (Milestone #22)
- **Scope:** the milestone's payoff — a **real tool**, not a hello-world, ported to wasm with `zig cc`, shipped as an HF4 app and used. Frozen: `wc` (byte/line/word counts over file-channel reads, printed byte-exact), integer-only, written against `tests/virelai.h` alone from `docs/wasm-import-contract.md` (the standalone-author provenance proof — D3). Reads a fixed `/host/WC.TXT` (wasm `_start` takes no argv; same hardcode pattern as fileapp's `/host/FILE.TXT`), streams it in 64-byte `env.file_read` chunks, counts bytes/lines/words with an in-word whitespace state machine that survives chunk boundaries, prints the classic three-column wc line right-aligned to the widest count, and exits with the total byte count (fileapp's length proof). The contract doc gains a worked-author-recipe block in §7 so the standalone-author promise is concrete. Live gate (`tools/verify-live-wasm.sh`): WC.WASM copied into the share + sha-pinned, a deterministic WC.TXT fixture written host-side, `exec WASM.BIN WC.WASM` in script1, byte-exact count line + `tasks user-exec exited status=<bytes>` + `rx-w5-wc` asserted per run.
- **Touches:** tests/wc.c (new — the app, written from the contract doc alone), user/src/wasm-corpus/wc.wasm (new pinned binary), user/src/wasm.zig (W5 host test: extend the HostCapture seam with a file-data simulation so the host test genuinely EXECUTES wc against the pinned bytes — parse → validate → instantiate → run, byte-exact output + exit = bytes; the capture already services env.write byte-exact), tools/verify-live-wasm.sh (W5 phase), docs/wasm-import-contract.md (§7 worked-author example + W5 provenance note), docs/wasm-core-scoping.md (W5 row when landed), docs/status.md (M35 row done), claim + branch log; claim id via `bash tools/status/claim-id.sh`
- **Depends on:** W4 #765 (claim 7395, done 2026-09-02); W1a #778 contract
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 agent/buffy2/m35-w5-wc-capstone

## Notes

The wc binary must be proven byte-identical through BOTH host-test and live
paths. Host test: the capture seam gains `file_data` + `file_pos`; the
`file_read` capture branch serves min(cap, remaining) from it via
`stageOut` (the existing store copy) — same honest 0-at-EOF, cap-clamped
semantics as the kernel path, but no svc #0. Live gate: same binary +
fixture, real file channel. Counts are cross-validated against an
independent Python reimplementation AND host `wc` on the same fixture
bytes before pinning (wc semantics: word = maximal run of non-whitespace
per the C locale; newline counts even at EOF-without-newline).

Gate: `zig test user/src/wasm.zig` green (new w5 exec test + all prior
green); `zig build wasm` + bss budget; `tools/verify-live-wasm.sh` W5
phase PASS on VZ (byte-exact counts + exit status); `verify-coordination`
PASS. Closing M35's last card leaves Milestone #22's tracker at 6/6 —
milestone closure rides the PR merge (owner action, per the M33 pattern).

Claim id derivation: `bash tools/status/claim-id.sh "agent/buffy2/m35-w5-wc-capstone" m35-w5-wc-capstone` → **5883** (the backticked owner branch, not the display name).