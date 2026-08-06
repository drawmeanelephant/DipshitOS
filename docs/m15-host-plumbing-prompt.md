# Milestone 1.5 — host plumbing (agent A): duplex serial attachment, live teeing, and the `console` command

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. It must produce a written plan **before** changing any
code.

- Branch: `agent/.../m15-host-plumbing` (claim first via a claim file in
  `docs/claims/` + a log entry in `docs/logs/`; merge per ADR 0003)
- Date: 2026-08-06
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`
  (M1.5 march steps 4–7, the "Best agent split" A row, the coordination
  rules, the changelog), `docs/testing.md`, `docs/hardware-contract.md`,
  `docs/decisions/0004-kernel-proper.md`,
  `host/vm-runner/Sources/VMRunner/main.swift`, `build.zig`, `justfile`.

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host on Apple
M4 / macOS 27, no QEMU path). Milestone 1.5 turns the milestone-two
kernel's serial console into an interactive monitor (`dipshit>`). Two facts
frame this slice:

- The guest console is **TX-only** (ADR 0004: no RX path) — the guest cannot
  yet read keystrokes; a guest RX path is agent B's slice, sequenced after
  the VZ serial gate proves which MMIO console is real.
- The runner's serial attachment is **output-only**: `VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)` in `main.swift` — host-to-guest input is `nil` today.

This slice makes the host able to send bytes into the guest and to show
live output **without sacrificing the reproducible evidence log**.

## Scope (steps 4–7 of `docs/status.md`)

1. **Step 4 — duplex serial attachment.** Give the serial attachment a
   readable host handle, initially standard input, so bytes typed in the
   host terminal can reach the guest serial device. Observable: the
   attachment's `fileHandleForReading` is no longer `nil`.
2. **Step 5 — tee guest output.** Show guest output live on the terminal
   **and** keep writing `artifacts/vm-serial.log`. The runner currently
   re-reads the log file on a timer (`Data(contentsOf:)`); replace that
   with the duplex attachment + a live tee so evidence survives interactive
   use.
3. **Step 6 — terminal state safety.** Raw/character-mode input with the
   terminal restored on exit and on signals (SIGINT/SIGTERM), so Ctrl-C
   leaves the user's shell usable. Backspace/Enter/Ctrl-C must behave
   predictably.
4. **Step 7 — first-class launch command.** Add `zig build console` and
   `just console`: one command builds, images, boots, and opens DipshitOS
   interactively.

## Do not

- Touch `kernel/` at all. The guest belongs to agents B/C; the guest RX
  path is a separate slice.
- Weaken the existing evidence gates: `zig build run` must keep producing
  `artifacts/vm-serial.log` with the same success/evidence semantics.
- Add libc/POSIX to the guest, or introduce any QEMU path.
- Claim end-to-end input works. Until the guest has an RX path, keystrokes
  can be *sent* but nothing proves the guest received them — report exactly
  what is observed and mark the rest `[inferred]`.

## Process (hard gate)

1. **Claim before you start.** Create `docs/claims/<NNN>-m15-host-plumbing.md`
   from the TEMPLATE (owner/branch, 🔄) and append a log entry in
   `docs/logs/agent-...-m15-host-plumbing.md` *before* writing code.
2. Read the binding inputs; restate in your plan how each step will be
   verified and what the observable evidence is.
3. Implement.
4. Verify per the gates below; save every command's output under
   `artifacts/m15-host-*.txt`.

## Verification gates

1. `swift build --package-path host/vm-runner` passes.
2. The attachment is duplex: `fileHandleForReading` is a real handle wired
   to stdin (not `nil`).
3. Live teeing works: during a `zig build console` run, guest output appears
   on the terminal as it arrives **and** `artifacts/vm-serial.log` captures
   it.
4. Terminal restore works: Ctrl-C and normal exit leave the terminal in a
   usable state (no raw-mode leakage).
5. `zig build run` still reaches the same observable state as before the
   change (evidence unchanged — record before/after).
6. `zig build console` and `just console` exist and boot the VM.

## Definition of done

- Host can send bytes into the guest serial device and see live output
  without losing the evidence log.
- Terminal is safe under exit/signals; one-command interactive launch
  exists.
- `docs/status.md` updated: steps 4–7 flipped with evidence files, changelog
  appended, claim closed.
- The end-to-end "keystroke reaches the kernel" proof is **deferred** to
  agent B after the serial gate (`docs/m2-vz-serial-gate-prompt.md`) — do
  not fake it in this slice.
