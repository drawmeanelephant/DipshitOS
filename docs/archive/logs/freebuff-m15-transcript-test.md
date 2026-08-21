# Log — M1.5 transcript test automation (`freebuff/m15-transcript-test`)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `freebuff/m15-transcript-test`):** claimed
  march step 19 — the automated transcript test. Scope: canonical fixture
  `tests/transcript-console.txt`, e2e test emits the captured mock transcript
  to `artifacts/m15-mock-transcript.txt`, `tools/verify-transcript.sh` runs
  the shell tests + byte-exact diff, wired as `zig build test-console` /
  `just test-console` / `just verify` / CI. Live `vm-serial.log` assertion
  explicitly deferred to claim 0002 (kernel `readByte` is a no-RX stub until
  the VZ serial gate proves a device). 🔄 in progress — no code written yet.
- **2026-08-06** — **M1.5 transcript test automation done (buffy,
  `freebuff/m15-transcript-test`):** implemented march step 19's named gate.
  `kernel/src/shell.zig` e2e test now emits the captured mock transcript to
  `artifacts/m15-mock-transcript.txt` via the Zig 0.16 `std.Io` interface
  (host-test-only; never in the freestanding image). Canonical fixture
  `tests/transcript-console.txt` (2299 B, `-text`-locked in a new
  `.gitattributes` so the intentional CR bytes survive checkout). New
  `tools/verify-transcript.sh`: runs `zig test kernel/src/shell.zig` then
  `diff -u` the emitted bytes against the fixture. Wired as `zig build
  test-console` (build.zig), `just test-console`, `just verify`, and a CI
  step. **Observed:** gate PASS (byte-identical), all 65 shell tests, all 7
  modules green via `verify-unit-tests.sh` (10/3/19/5/41/65/50), `zig fmt
  --check` and `zig build` pass, `verify-coordination.sh` ok — evidence
  `artifacts/m15-transcript-{gate,unit-tests,coord}.txt`. March row 19
  flipped ✅ (mock). **Not claimed:** the live `vm-serial.log` assertion —
  gated on claim 0002 (kernel `readByte` is a no-RX stub until a device is
  proven). ✅ — mock-level gate landed, hardware unclaimed.
