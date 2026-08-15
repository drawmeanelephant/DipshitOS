# Claim: milestone eight, card U3 — error/usage contract (ADR 0008 D3)

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m8.md` U3 row — the mechanical enforcement
  of ADR 0008 D3: one `usage:` shape, one `error:` shape, one `unknown
  command` shape, no handler panics, a byte-exact misuse transcript, and a
  host fuzz of the tokenizer and handlers.
- **Scope:** `kernel/src/monitor.zig` (uniform shapes across ~100 output
  sites: dispatch-level `usage:`/`unknown command` + a `print_usage` /
  `err_prefix` helper pair, then every sub-verb misuse → `usage: <cmd>`,
  every refusal/failure → `error: <actionable>`); `kernel/src/shell.zig`
  (transcript misuse coverage + the fuzz harness); `kernel/src/lineedit.zig`
  (a latent width bug the fuzz found). No syscalls, no ADR 0007 change.
- **Depends on:** U0 (ADR 0008, claim 8938), U1 (claim 3275), U2 (claim
  1809 — the history path the fuzz broke).
- **Status:** ✅ done 2026-08-14

## Notes

The D3 contract is now a *mechanically enforced* invariant, not prose:

1. **Misuse** → `usage: <cmd> <args>` (the registry's ONE usage string per
   command, via `print_usage`; sub-verb misuse reuses the command's full
   usage so a fourth shape cannot slip in on a bad invocation).
2. **Failure** → `error: <actionable message>` (`err_prefix`); includes
   storage, machine-control, win, kill, netsend, screen/text, exec, and the
   whole net family.
3. **Unknown verb** → `unknown command '<x>' -- try 'help'`.

The two-hyphen `--` is the byte-safe rendering of the ADR's typographic em
dash: the framebuffer text layer renders only 0x20..0x7e, so a multi-byte
dash would render as blanks on-screen (documented in the source).

## Verified

- **Class A** — `zig fmt --check` clean; monitor 358 tests green (all stale
  expectations updated to the new shapes; `.usage`/`.invalid_argument`
  returns tightened where a misuse now returns `.usage`); shell 396 tests
  green; tokenizer 367 + lineedit 28 green. The byte-identical transcript
  (`shell.zig` e2e + `tests/transcript-console.txt`) now exercises all three
  shapes: `usage: pages [selftest]` (misuse), `error: hello.txt: not
  persisted - no disk (FAT volume unavailable)` + `error: hello.txt: not
  found (no such file on the ESP)` (failure), and the long-line `unknown
  command '<256 a's>' -- try 'help'` (unknown verb). Full `verify-portable`
  set green (build/image/inspect/context, swift build, coordination,
  test-coordination, mmu-debt, glyph self-test).
- **New host fuzz (the card's gate)** — three deterministic-seed fuzz tests
  in `kernel/src/shell.zig`: (1) the tokenizer over 4000 random byte
  streams — never panics, every token stays an in-bounds slice of the line,
  `count <= max_tokens`, `too_many` only with a full count; (2) `exec` over
  4000 random argv arrays (random counts up to the registry bound, random
  bytes incl. control/high bytes) through the real boot-shaped env — never
  panics; (3) the full input path (editor + tokenizer + handlers) over 1500
  random keyboard alphabets (letters, Enter, Ctrl-C/L, ESC-prefixed chords,
  backspace, DEL, non-ASCII) — never panics, shell still responsive.
- **Root-caused + fixed en route** — the full-path fuzz found a latent U2
  width bug: `remember_line`'s `@min(hist_count, hist_capacity - 1)` with
  the comptime bound (= 15) inferred **u4** for the shift count, so `keep +
  1` overflowed on the **16th distinct history entry** — the ring filled
  exactly once and the shell panicked (integer overflow in Debug).
  Fix: an explicit `const keep: usize = @min(...)` anchor, plus a regression
  test (`history ring never overflows past capacity`) that fills the ring
  past capacity and walks recall across every slot. The fuzz passed
  unchanged after the fix — no input was weakened or skipped.
- **Class B** — `tools/verify-live-help.sh` **PASS 1/1 on VZ** (grouped
  catalog + `help <cmd>` + `help <topic>` live) and
  `tools/verify-live-transcript.sh` **PASS 1/1 on VZ** (live RX transcript)
  — both re-run green after the shape conversion; the live surfaces now
  show the new `error:`/`usage:` forms.
