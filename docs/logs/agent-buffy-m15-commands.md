# Log — `agent/buffy/m15-commands` (PR #12)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `agent/buffy/m15-commands`):** claimed
  the M1.5 commands & personality row (steps 12–18). Per the C-prompt
  process gate: design written first (`docs/m15-commands-design.md`), all
  code in new `kernel/src/*.zig` modules (`console.zig`, `monitor.zig`,
  `handoff.zig`, `memmap.zig`) with host-side `zig test` coverage against a
  mock console; `kernel/src/main.zig` untouched. 🔄 in progress — no code
  written yet.
- **2026-08-06** — **M1.5 commands & personality slice done (buffy,
  `agent/buffy/m15-commands`):** implemented and host-tested the monitor
  command layer in four new kernel modules: `console.zig` (transport-agnostic
  `Console` interface + bounded `MockConsole`), `handoff.zig` (handoff-v2
  struct + validation, ADR 0004 D5), `memmap.zig` (captured-map view +
  saturating summary), `monitor.zig` (comptime registry, `lookup`/`exec`,
  `MachineControl` interface + honest `disabled()` default, all 14 commands:
  help/about/version/uname/handoff/mem/echo/clear/hex/repeat/reboot/shutdown/
  elephant/beans, boot-message pool + banner). Design in
  `docs/m15-commands-design.md`. **Observed:** `zig fmt --check` pass,
  `zig build`/`zig build image`/`zig build inspect` pass (no regression),
  `zig test` 53/53 pass on the host (console 7, handoff 3, memmap 5, monitor
  38) — no VZ, no serial device; evidence `artifacts/m15-commands-{fmt,build,
  image,inspect,tests}.txt`. Step-15 fs decision recorded (defer to storage
  milestone; hard gates 5/6 stay open). `kernel/src/main.zig` has zero diff
  (gate 3). ✅ — on branch awaiting merge through the
  `m1.5-interactive-monitor` integration branch.
- **2026-08-06** — **Correction (buffy, `agent/buffy/m15-commands`):**
  the `m1.5-interactive-monitor` integration branch was **never created**;
  streams A and C targeted `main` directly per ADR 0003 / branch
  protection (PRs #12/#13 — see march step 3 in `docs/status.md`). This
  entry supersedes the "awaiting merge through the integration branch"
  wording in the slice-done entry above. ✅
