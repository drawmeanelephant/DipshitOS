# Claim: milestone eight, card U1 — grouped help catalog + topics

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m8.md` U1 row — the first milestone-eight code
  card, implementing ADR 0008 D1's discovery surface on top of U0.
- **Scope:** `kernel/src/monitor.zig` only (plus the transcript fixture/gate and
  docs). Group the 40-command registry into the ADR 0008 D1 categories, rewrite
  `help` into a grouped catalog + `help <command>` detail + `help <topic>`
  pages, and wire every command's usage string (already present) so misuse
  shows it. No handler behavior changes, no new syscalls.
- **Depends on:** U0 (ADR 0008, claim 8938).
- **Status:** ✅ done (2026-08-14)

## Notes

The registry already carried `name`/`help`/`usage`/`min_args`/`max_args` per
command and already printed `usage: <usage>` on argument-count misuse; U1's
increment is the *catalog*: a `Category` field, a grouped `help` listing in
the ADR D1 group order, and topic pages reachable through `help <topic>`.

Topics (non-command keywords): `networking`, `windows`, `storage`, `graphics`.
`syscalls` and `input` are commands, so `help syscalls` / `help input` resolve
to their command detail — that is their page; the ADR's "syscalls" topic
example is subsumed by the command rather than duplicated as a shadowed topic.

## Verified

- ✅ `kernel/src/monitor.zig`: `Category` enum + `category_order`/`category_name`
  (PC-relative string returns, the claim-0015 no-relocation lesson), a
  `category` field on all 40 registry entries, `topic_body()` (4 pages), and a
  rewritten `cmd_help` (grouped catalog / `help <cmd>` detail / `help <topic>`).
- ✅ class A: `zig fmt --check` clean; 352 monitor tests pass (incl. two new:
  topic pages + command-wins, and the grouped-by-category order); the
  byte-identical transcript test + `tests/transcript-console.txt` fixture
  regenerated to the grouped listing (fixture line endings preserved via
  `cp` from the emitted transcript — the `.gitattributes -text` contract).
- ✅ `just verify-portable` set (fmt, unit tests, test-console, build, image,
  inspect, swift build, context, coordination, test-coordination, mmu-debt,
  glyph self-test) all green.
- ✅ class B: new `tools/verify-live-help.sh` PASS 1/1 on VZ — the scripted
  `help`/`help net`/`help <topic>`/`help syscalls` walk asserts the grouped
  catalog, command detail, and all four topic pages in `vm-serial.log`
  (evidence `artifacts/live-help-*`). Registered in `justfile` (`verify-vz`
  + `verify-live-help`) and `docs/gate-inventory.md` (`live-help` row +
  `GATE id=`).
