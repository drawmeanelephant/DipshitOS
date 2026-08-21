# Claim: M1.5 — console & shell core (agent B)

- **Owner:** buffy (`freebuff/milestone-1-5-console-shell-core-agent-b-rx-read-p-2ee77bfe-eac9-4018-b5e1-ea38a0080268`)
- **Prompt / plan:** M1.5 steps 9–11 + prompt loop (`docs/m15-shell-core-design.md`)
- **Scope:** console read path (mock-testable), bounded line editor, tokenizer, `dipshit>` prompt loop wired into the kernel terminal WFE loop; mock-console based, transport-agnostic
- **Depends on:** A (host plumbing) proving input reaches the serial attachment (✅, PR #13); live RX additionally gated on the VZ serial gate (`docs/claims/0002-vz-serial-gate.md`, 🔄)
- **Status:** ✅ 2026-08-06 — mock-tested loop (banner → prompt → lineedit → tokenize → exec); hardware unclaimed

## Notes

New kernel modules: `lineedit.zig` (256-byte bounded editor), `tokenizer.zig`
(fixed arity, ≤ 17 tokens), `shell.zig` (banner/prompt/loop + WFE-park
fallback). `console.zig` gained a polled `readByte` vtable slot and a
scripted `MockConsole` input queue. `kernel/src/main.zig` gained **only** the
prompt-loop seam (imports + one `shell.boot_and_park` call); the takeover
path (ExitBootServices, MMU, probe, `uart_*`) is byte-identical (gate 5,
verified by diff). `tools/verify-unit-tests.sh` MODULES list extended with
the three new modules.

**Observed:** `zig fmt --check` pass, `zig build`/`image`/`inspect`/`context`
pass (no regression), `zig test` green for all 7 modules via
`bash tools/verify-unit-tests.sh` (per-module gate output: console 10,
handoff 3, lineedit 19, memmap 5, monitor 41, shell 65, tokenizer 50 —
counts include transitively imported tests), mock-fed end-to-end loop
transcript asserted byte-for-byte — evidence
`artifacts/m15-shell-core-*.txt`.

**Not claimed:** live RX and end-to-end keystroke → command. The kernel
adapter's `readByte` is an `[inferred]` no-RX stub until the VZ serial gate
(claim 0002) passes; no device register is read.

Design: `docs/m15-shell-core-design.md` · Log:
`docs/logs/agent-buffy-m15-shell-core.md`
