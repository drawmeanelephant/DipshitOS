# Claim: M1.5 — console & shell core (agent B)

- **Owner:** —
- **Prompt / plan:** M1.5 steps 9–12 (prompt doc to be written)
- **Scope:** RX path + console abstraction (`uart` + read), line editor, tokenizer, command registry, prompt loop
- **Depends on:** A (host plumbing) proving input reaches the serial attachment
- **Status:** ⬜ unclaimed

## Notes

The monitor command layer (agent C) already exists against a mock console;
this slice wires the live console, line editing, tokenization, and the
`dipshit>` prompt loop into the kernel's terminal WFE loop. Depends on the
VZ serial gate outcome (`docs/claims/0002-vz-serial-gate.md`) for which
MMIO console is real.
