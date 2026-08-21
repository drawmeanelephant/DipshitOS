# Claim: M1.5 — commands & personality (agent C)

- **Owner:** buffy (`agent/buffy/m15-commands`)
- **Prompt / plan:** M1.5 steps 12–18 (`docs/m15-commands-prompt.md`)
- **Scope:** command registry, identity/memory/utility/control commands, personality — mock-console based, new kernel files only
- **Depends on:** mock console (can land before A's input proof)
- **Status:** ✅ 2026-08-06 — 14 commands host-tested, `kernel/src/main.zig` untouched

## Notes

New kernel modules: `console.zig`, `handoff.zig`, `memmap.zig`,
`monitor.zig` (comptime registry, 14 commands, MachineControl interface
with honest `disabled()` default, boot-message pool + banner). Design in
`docs/m15-commands-design.md`. Step-15 fs decision recorded (defer to a
storage-driver milestone; hard gates 5/6 stay open). **Observed:** 53/53
`zig test` pass on host, build gates green (`artifacts/m15-commands-*.txt`).
Log: `docs/logs/agent-buffy-m15-commands.md`.
