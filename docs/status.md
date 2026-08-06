# DipshitOS living status & goals

> This file is the project's **living status tracker**: where we are, what we
> are trying to build next, and how far along each step is. Update it as work
> lands — flip the checkboxes, fill in the notes, and append to the status
> log at the bottom. Claims stay honest per `AGENTS.md`: **observed** (log
> evidence under `artifacts/`) versus **inferred** (reasoning/docs only).

> **Premise check (2026-08-06):** this tracker was first frozen against the
> milestone-one-era `main`. On the same day, PRs #6/#7 merged the
> **milestone-two kernel proper** (ADR 0004), which changed the premises
> below: the kernel now calls `ExitBootServices`, owns an identity-map MMU,
> drives a polled TX-only MMIO serial console, and never returns. This file
> was refreshed accordingly — the plan's shape is kept, its factual anchors
> are reconciled with the merged state.

## Current position

| Milestone | What it proved / is | Status |
|-----------|---------------------|--------|
| Zero — boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware; output observed on host (`\BOOTED.TXT`) | ✅ done |
| One — kernel handoff | Separate freestanding `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`\RC.TXT` = `kernel_rc=0x0`); ADR 0002 | ✅ done |
| Two — kernel proper | ExitBootServices, captured EFI map, identity TTBR0_EL1 tables, MMIO serial probe + polled TX console (ADR 0004) | 🔄 **attempted; VZ hardware gate blocked** (no serial/`RC.TXT` evidence yet; MMIO/MMU assumptions still `[inferred]`) |
| **1.5 — Interactive Kernel Monitor ("Dipshit Monitor")** | A live, interactive command monitor served by the kernel's serial console (the milestone-two terminal loop becomes its payload) | 🎯 **current** |
| Three+ — allocator, interrupts, tasks | Physical allocator, GIC + timer, then processes | ⏳ deferred (roadmap) |

Resolved loose end: the milestone-one `KERNEL.TXT` corruption is **fixed**
(ADR 0002 — the loader now places image content at `base+0`; the write is
byte-perfect and gated by `zig build run`).

## Milestone 1.5 — the call

Do **not** add more kernel-proper plumbing before making the machine
interactive. The milestone-two kernel already owns the machine: it ends UEFI
Boot Services, installs its own page tables, probes the MMIO serial
candidates (PL011/16550/virtio-MMIO), and drives a polled **TX-only**
console (ADR 0004 — "no interrupts, no FIFO/DMA, no RX path") before
entering a terminal WFE loop. That console is exactly enough to serve an
interactive monitor — the monitor is simply the loop's payload. No new
firmware dependencies, no allocator, no interrupts, no storage drivers.

One immediate blocker, on both ends of the wire: the kernel console has **no
RX path at all** (ADR 0004), and the VM runner's serial attachment sends
guest output to a file but its host-to-guest input handle is `nil`
(`VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)` in
`host/vm-runner/Sources/VMRunner/main.swift` — unchanged on the merged
`main`). Until keystrokes can reach the guest, the monitor is output-only.

### Definition of done — the target screen

```text
DIPSHITOS 0.1
AArch64 firmware-assisted kernel monitor
256 MiB detected
Type 'help' before touching anything expensive.

dipshit> help
about      explain this questionable system
cat        print a file from the ESP
clear      clean up the crime scene
echo       repeat your regrettable decisions
elephant   operational mascot diagnostics
handoff    display boot-to-kernel ABI data
ls         list files on the ESP
mem        summarize the EFI memory map
reboot     restart the machine
shutdown   request power-off
version    display build information
write      write text to a file

dipshit>
```

### Hard gates (acceptance criteria)

- [ ] `zig build`, `zig build image`, and the existing regression checks still pass.
- [ ] `zig build console` reaches `dipshit>`.
- [ ] Host keystrokes reach the kernel (RX path closed end to end).
- [ ] At least ten commands work.
- [ ] `ls`, `cat`, and `write` persist through reboot — **needs re-scoping**: post-exit there is no ESP root / Simple File System (x3 carries handoff v2), so these need a pre-exit file window or a storage driver; see step 15.
- [ ] A scripted console session passes automatically (asserting in `vm-serial.log`).
- [ ] The VM can reboot or shut down from the shell.
- [ ] No allocator, MMU replacement, interrupts, scheduler, or userspace is falsely claimed.

## The twenty-step march (living tracker)

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Step | Observable result | Status | Notes / evidence |
|---:|------|-------------------|--------|------------------|
| 1 | **Freeze the target.** Name it Milestone 1.5: Interactive Kernel Monitor. Keep the milestone-two kernel exactly as merged (no new firmware work). | Scope document says exactly what counts as done and what is deferred. | ⬜ | This file is the scope/status doc. |
| 2 | **Define the finish line.** Boot into a terminal, display a banner, accept commands at `dipshit>`, execute ≥ 10 useful commands. | Written acceptance checklist (above) prevents agents from wandering into scheduler astrology. | ⬜ | Hard gates listed above; fs gate flagged for re-scope. |
| 3 | **Create a dedicated integration branch.** e.g. `m1.5-interactive-monitor`. | All monitor work has one landing zone while agents use smaller branches. | ⬜ | See ADR 0003 branch rules. |
| 4 | **Add interactive mode to the Swift runner.** Give `VZFileHandleSerialPortAttachment` a readable host handle, initially standard input. | Bytes typed in the host terminal can reach the guest serial device. | ⬜ | Input handle is `nil` today (verified in `main.swift` on merged `main`). |
| 5 | **Tee guest output.** Send output to the terminal **and** `artifacts/vm-serial.log`. | Interact live without sacrificing reproducible evidence. | ⬜ | Runner currently polls the log file (`Data(contentsOf:)`); upgrade to duplex + tee. |
| 6 | **Handle terminal state safely.** Raw/character-mode input; restore the terminal on exit and signals. | Backspace, Enter, Ctrl-C behave predictably. | ⬜ | |
| 7 | **Add a first-class launch command.** `zig build console` and `just console`. | One command builds, images, boots, and opens DipshitOS interactively. | ⬜ | |
| 8 | **Confirm the serial console.** The M2 probe (`probe_serial`) already selects a MMIO candidate (PL011/16550/virtio-MMIO); verify which kind/base it drives and that TX reaches `vm-serial.log` on a real VZ run. | Log proves console kind + base and the first post-exit serial evidence (`DipshitOS kernel has seized control.`). | ⬜ | This replaces the plan's "probe UEFI Serial I/O" step: post-exit there is no UEFI Serial I/O protocol; M2's probe is the mechanism. VZ gate currently blocked (no serial evidence on the saved run). |
| 9 | **Build a console abstraction.** `write`, `putc`, `flush` on top of the M2 `uart` module; `readByte` is the RX gap to close (step 4 host side + a guest RX path). | Kernel code stops caring which MMIO candidate carries the bytes. | ⬜ | ConOut fallback is dead post-exit; primary = MMIO uart. |
| 10 | **Make input bounded and boring.** Fixed 256-byte line buffer; CR/LF, backspace, Ctrl-C, overflow rejection. | Editable command lines without an allocator. | ⬜ | |
| 11 | **Implement tokenization.** Fixed argument count, whitespace handling, optional quoted strings. | `echo "elephant business"` works without heap allocation. | ⬜ | |
| 12 | **Create a command registry.** Name, help text, function pointer per command; `help` generated from the registry. | Adding commands is mechanical. | ⬜ | |
| 13 | **Add identity commands.** `help`, `about`, `version`, `uname`, `handoff`. | The system explains what it is, how it booted, and which ABI it received (handoff **v2** struct — x3 is no longer the ESP root). | ⬜ | |
| 14 | **Add memory inspection.** `mem` from the EFI map the kernel captured **before** `ExitBootServices`: total conventional RAM, reserved regions, descriptor count, kernel bounds. | CLI reports actual machine state. | ⬜ | 256 MiB configured in the runner; banner claims "256 MiB detected". No `GetMemoryMap` post-exit — use the captured map. |
| 15 | **Add filesystem commands.** Root-only `ls`, `cat`, `write`, `touch` on the ESP. | Decision point: the ESP root died with Boot Services (x3 carries handoff v2). Either a **pre-exit file window** (kernel reads/writes evidence files before exit and the monitor reports them) or defer fs commands to a real storage driver milestone. | ⬜ | Hard gate 5 depends on this decision. Until then the monitor's fs commands are output-only (report the captured files). |
| 16 | **Add basic shell utilities.** `echo`, `clear`, `hex`, `repeat`. | The monitor feels like a tiny environment. | ⬜ | |
| 17 | **Add machine controls.** `reboot`, `shutdown`, `halt` via the Runtime Services table captured pre-exit (`ResetSystem` survives ExitBootServices) or a documented fallback (WFE loop / VM teardown). | The session can end intentionally. | ⬜ | |
| 18 | **Install the sacred nonsense.** `elephant`, a rotating boot message, and one deeply stupid command (`beans`). | DipshitOS has an identity. 🐘 | ⬜ | |
| 19 | **Automate the transcript test.** Feed `help`, `version`, `mem`, `echo test`; assert exact output in `vm-serial.log`. | `zig build test-console` proves prompt + commands without manual typing. | ⬜ | Gate on bytes the kernel actually sent, not on file evidence. |
| 20 | **Close the milestone honestly.** Update README, roadmap, architecture, testing docs; regenerate the deterministic context snapshot; tag only after all gates pass. | Repo says "interactive firmware-assisted kernel monitor", not "complete OS". | ⬜ | |

## Best agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Host plumbing** | Swift runner, duplex serial attachment, terminal handling, output teeing, `zig build console`, scripted input | — |
| **B — Console & shell core** | RX path + console abstraction (`uart` + read), line editor, tokenizer, command registry, prompt loop | A proving input reaches the serial attachment |
| **C — Commands & personality** | Memory reporting (captured map), fs-command decision, reboot/shutdown, banner, `elephant`, documentation, transcript fixtures | Can build against a mock console before A's proof lands |

Merge through the integration branch — do not let three agents redecorate
`kernel/src/main.zig` with chainsaws at once.

## What comes immediately afterward

Once the monitor is stable, the command layer is portable; the plumbing is
already milestone-two. What remains after M1.5:

1. A real RX path (virtio-console or discovered MMIO UART RX) — the
   kernel's console is TX-only today (ADR 0004).
2. A physical page allocator over the captured EFI map.
3. Exception vectors, GIC + timer interrupts — then, and only then, talk
   about tasks or userspace.

That keeps a useful CLI on the milestone-two kernel without faking a
"complete OS", while the shell architecture survives the console driver
change.

## Assumptions & gaps in this plan (checked against the merged `main`)

- **ADR 0004 now exists and matches the plan's citation.** It is the
  milestone-two kernel-proper ADR; its console is polled TX-only with
  explicitly "no RX path" — exactly the constraint the plan warned about
  ("VZ may expose only a virtio console rather than a simple MMIO UART").
  The M2 kernel probes PL011/16550/virtio-MMIO candidates and selects one;
  which one wins on VZ is still **unobserved** (the VZ run gate is blocked).
- **Runner serial input is `nil` today.** Verified on merged `main`:
  `VZFileHandleSerialPortAttachment(fileHandleForReading: nil, ...)` in
  `host/vm-runner/Sources/VMRunner/main.swift` — step 4 is a real change.
- **Output observation is still file-polling.** The runner re-reads the
  serial log (`Data(contentsOf:)`) on a timer; steps 4–6 replace this with a
  duplex attachment, live teeing, and terminal-state management.
- **"256 MiB detected"** matches the runner's configured
  `memorySize = 256 * 1024 * 1024` (unchanged on merged `main`); `mem`
  should derive it from the captured map, not hardcode it.
- **The kernel is post-Boot-Services and never returns.** `ExitBootServices`
  is called (ADR 0004), `x3` is the handoff v2 struct (not the ESP root),
  and the kernel ends in a WFE loop. Consequences baked into the steps
  above: no UEFI Serial I/O protocol probe, no `GetMemoryMap`, no Simple
  File System — the monitor is the terminal loop's payload.
- **VZ firmware quirks still apply:** `ConOut` is not routed to the virtio
  serial port or framebuffer, and the milestone-two VZ run produced no
  serial output or `RC.TXT` (MMIO/MMU assumptions stay `[inferred]`).
  Transcript tests must gate on bytes the kernel actually sent via `uart_puts`.

## Status log

- **2026-08-06** — Milestone 1.5 scope frozen and this living tracker
  created from the "Dipshit Monitor" plan (premises: milestone-one-era
  kernel on Boot Services). All gates open.
- **2026-08-06** — **Refresh:** PRs #6/#7 merged the milestone-two kernel
  proper (ADR 0004). Reconciled premises: post-exit kernel, polled TX-only
  MMIO console, no ESP root, no `GetMemoryMap`; ADR 0004 now exists;
  `KERNEL.TXT` corruption resolved. Fs commands (step 15 / gate 5) flagged
  as a decision point. No implementation steps started.
