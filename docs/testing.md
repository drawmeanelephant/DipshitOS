# DipshitOS testing

> For the current state of each verification gate (pass/fail/blocked), see
> [`docs/status.md`](status.md). This file is the sequence and policy. The
> canonical A/B/C/D classification of every verification command is
> [`docs/gate-inventory.md`](gate-inventory.md).

## Verification classes

Every verification command belongs to exactly one class (canonical inventory:
[`docs/gate-inventory.md`](gate-inventory.md)):

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  This is the set GitHub CI proves. A green CI badge means exactly these
  passed — nothing more.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon (macOS 27+ — the project's required host).
  GitHub-hosted CI does **not** run these and cannot prove them; run
  `just verify-vz` on a development host.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard (`zig build console`).
- **D — diagnostic experiment.** Answers a question (claims
  0017/0018/0020/0021/6460); **not an acceptance gate**.

## Evidence policy

- **Observed** = the claim is backed by command output or a log file saved
  under `artifacts/`. Only observed behavior is reported as "works".
- **Inferred** = we believe it from documentation or reasoning, but have no
  log. Inferred claims are always labeled as inferred.
- We do not fabricate successful command output. If a required dependency or
  platform capability is unavailable, everything else still runs and the
  blocked step is reported precisely.

## Verification sequence

1. Print the detected tool versions.
2. Check Zig formatting: `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`.
3. Run the M1.5 kernel monitor module unit tests:
   `bash tools/verify-unit-tests.sh` — runs `zig test` on each module
   present in `kernel/src/` (console/handoff/memmap/monitor). Modules that
   have not landed yet are skipped with a notice, so the gate stays green
   on `main` and becomes binding branch-protection evidence once each
   module merges.
4. Run the automated transcript gate (M1.5 march step 19):
   `zig build test-console` (also `just test-console`; CI runs
   `tools/verify-transcript.sh`) — the shell module tests plus a byte-exact
   diff of the mock-console transcript against the canonical fixture
   `tests/transcript-console.txt`.
5. Build the Zig UEFI application: `zig build`.
6. Inspect the generated binary: `zig build inspect`.
7. Create the FAT disk image: `zig build image`.
8. Inspect the disk-image contents (part of `zig build inspect`).
9. Build the Swift VM runner: `swift build --package-path host/vm-runner`.
10. Boot with Apple Virtualization.framework (Apple silicon only):
    `zig build run`. Milestone two gates on `vm-serial.log` containing the
    exact banner `DipshitOS kernel has seized control.`, a
    `memory-map descriptors=0x...` line, and `kernel terminal state`. The
    pre-exit loader marker `\\BOOTED.TXT` remains required. `RC.TXT` is
    expected only for a deliberate pre-exit failure fixture, not success.
    **Passing since 2026-08-08 (claim 1517)** — the post-MMU virtio TX
    blocker (translation start-level mismatch, claims 6460/7896) is fixed
    in production (T0SZ=16 + `tlbi vmalle1` at the switch); see
    `docs/status.md` for gate state.
11. Run the pre-exit failure-path gate:
    `bash tools/verify-bad-handoff.sh` (also `just verify-bad-handoff`) —
    boots a bad-magic fixture and asserts the loader's `RC.TXT` reads
    `kernel_rc=0x2`; **passing since 2026-08-06** (shim LR clobber fixed,
    claim 0001).
12. Run the ADR 0004 D4 marker fallback gate (gate work item 3, claims
    0009/0010): `bash tools/verify-marker.sh` (also `just verify-marker` /
    `zig build marker`) boots the VM and asserts the NVRAM marker ladder —
    the kernel persists each takeover stage as the EFI variable
    `DipshitM2`, and the runner saves the ordered ladder to
    `artifacts/marker-dump.txt`. The gate passes iff at least one marker
    instance is present; the final stage names the death/crash site. Claim
    0009 observed the ladder ending at `M2_MAPD!` (MMU-takeover window);
    claim 0010 root-caused and fixed it — the ladder now runs
    `M2_MAPD! → M2_MMUP! → M2_SERIA → M2_READY`, i.e. the switch completes
    and the probe/transport are reached (decoded later, claim 0013 — the
    real console is a virtio-pci device outside the declared windows). The
    memory-dump form is impossible on VZ (guest RAM is not host-mapped —
    observed, claim 0009).
13. Run the claim-0015 NVRAM console gate:
    `bash tools/verify-nvram-console.sh` (also `just verify-nvram-console`;
    mechanism `zig build nvram-console`; Apple silicon only) —
    reconstructs the kernel's post-exit console stream from `efi-vars.bin`
    (takeover banner, memory map, probe record, shell banner, and real
    `version`/`mem`/`echo`/`help` output — 69–70 chunks); **passing since
    2026-08-07** (`artifacts/nvram-console-gate.txt`). The gate also found
    and fixed the ADR 0005 flat-loader relocation bug (const
    function-pointer tables are not relocated by the flat loader).
14. Run the M1.5 host-side console plumbing gate (march steps 4–7):
    `bash tools/verify-host-console.sh` (also `just verify-host-console`;
    Apple silicon only) — wires a stdin-backed serial attachment, tees
    guest output to terminal + `vm-serial.log`, and restores the terminal
    on exit/signals.
15. Save command output and logs under `artifacts/m2-*.txt`, including the
    probe output and the complete serial log. State blocked VZ capabilities
    precisely rather than inferring success.

> **Historical regression check (ADR 0002, resolved):** the `\KERNEL.TXT` content gate
> in `zig build run` is the regression check for the loader's
> content-at-`base+0` addressing invariant (ADR 0002). A future loader
> change that reintroduces the old `base+24` layout (the 24-byte DSK1
> header loaded into RAM) makes the kernel's `adrp`+`add` references read
> 24 bytes early, so `KERNEL.TXT` is not byte-perfect and the run gate —
> and therefore CI — fails immediately.
16. Generate the project snapshot: `zig build context` →
    `artifacts/context.md`.
17. Verify the multiagent coordination surface:
    `bash tools/verify-coordination.sh` (also `just verify-coordination`
    and CI). Fails if a claim/log file is malformed, if a claim numbered
    `0024+` does not carry its deterministic ID (computed from the owner
    branch + filename slug by `tools/status/claim-id.sh`; `0001–0023` are
    grandfathered), or if the generated claim/log index tables in
    `docs/claims/README.md` / `docs/logs/README.md` drift from the files
    or are structurally malformed (every row must have the exact expected
    column count, so an unescaped `|` in a claim status cannot corrupt a
    table). Fix by running `bash tools/status/refresh-indexes.sh` after
    creating a claim file or branch log.
18. Test the coordination tooling itself: `bash
    tools/status/test-coordination.sh` (also `just test-coordination` and
    CI) — positive/negative cases for cell escaping, structural table
    validation, and deterministic claim IDs, run in a throwaway sandbox.
19. Run the live RX / transcript gate (class B, claim 6684):
    `bash tools/verify-live-transcript.sh` (also `just
    verify-live-transcript`) — boots the production image, forwards
    scripted keystrokes (`help`/`version`/`mem`/`echo`) into the guest's
    virtio receive queue after the takeover, and asserts the live
    `dipshit>` transcript (banner, echoed commands, command output, echo
    reply) in `vm-serial.log`. **Passing 2026-08-08** (3/3 boots,
    byte-identical transcripts; evidence `artifacts/live-transcript-*`).

> The full class-A (portable, no-VM) gate set runs as `just verify-portable`
> (legacy alias `just verify`) and in CI (`.github/workflows/ci.yml`): fmt →
> unit tests → transcript gate → `zig build` → image → inspect → Swift
> runner build → context → coordination → coordination tooling tests.
> **CI proves only this class** — a green badge says nothing about the
> Apple-silicon VZ hardware gates (class B). Those run as `just verify-vz`
> (serial takeover `zig build run`, bad-handoff, marker, NVRAM console,
> host-console, live transcript/RX `verify-live-transcript.sh`, live fs
> `verify-live-fs.sh`, live exceptions, live timer, live reboot/shutdown
> `verify-live-reboot.sh` — Apple silicon only); the class-D diagnostics
> (preexit-tx, tx-diag,
> tx-transition, fw-mmu-capture, t0sz25, walk-probe, t0sz16-walkprobe)
> run individually per claim. See
> [`docs/gate-inventory.md`](gate-inventory.md).

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Kernel serial probe, exact banner, map hex view, and terminal marker |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM; holds the `DipshitM2` marker ladder after a marker-gate run |
| `artifacts/marker-dump.txt` | `zig build marker` / `verify-marker.sh` | Ordered M2_* NVRAM marker ladder (ADR 0004 D4 fallback) |
| `artifacts/m2-marker-gate.txt` | `verify-marker.sh` | Full marker-gate run log (2026-08-07: ladder ends `M2_MAPD!`) |
| `artifacts/context.md` | `zig build context` | Full deterministic project snapshot |
| `\LOADER.TXT` on the ESP | loader (`zig build run`) | Loader-observed placement and handoff-v2 jump inputs |
| `\RC.TXT` on the ESP | loader, only after pre-exit failure | Non-zero kernel status for the bad-handoff fixture |
| `\MEMMAP.TXT` on the ESP | boot stub, before handoff | Pre-exit EFI memory map evidence |
| `\KERNEL.TXT` on the ESP | milestone-one regression only | Not written after the kernel exits Boot Services |
| `artifacts/m2-probe.log` | kernel serial output | Candidate reads, signatures, selected transport, and observed/inferred decision |
| `\KERNEL.BIN` on the ESP | `zig build` | Flat kernel image, verified with `elf2bin.py --info` |

## How output is observed

- **Virtualization path (observed findings on macOS 27 / Apple M4; the
  project targets Apple silicon only, no QEMU path):**
  - The virtio serial console stays empty: Apple's EFI firmware does not
    route `ConOut` there.
  - The virtio-gpu framebuffer stays blank: the firmware renders no text
    console to it (captured PNGs are gray/black, OCR finds no text).
  - Therefore the guest also writes its message to `\BOOTED.TXT` on the
    ESP through the UEFI Simple File System protocol, and `zig build run`
    prints that file back from the host. The file's presence and exact
    content is the observed proof of execution on Apple silicon.

## Results log (as verified on the development host)

> Current pass/fail/blocked state lives in [`docs/status.md`](status.md);
> this log is the dated historical record, kept because it is labeled.

- [x] `zig build` compiles `BOOTAA64.EFI` (PE32+ EFI application, AArch64)
- [x] `zig build inspect` reports a valid AArch64 PE/COFF EFI application
- [x] `zig build image` creates a GPT+FAT32 image with `EFI/BOOT/BOOTAA64.EFI`
- [x] Virtualization.framework boot executed the guest (observed via
      `\BOOTED.TXT` on the ESP)
- [x] Milestone one remains covered by the historical evidence in
      `artifacts/m1-fix-run{1,2,3}.txt`.
- [x] Milestone two VZ serial/MMU takeover gate: **PASS 2026-08-08 (claim
      1517)** — `zig build run` puts the banner, memory-map print, and
      `kernel terminal state` in `vm-serial.log` (post-MMU virtio TX
      fixed: T0SZ=16 + TLBI at the switch). Historical path (pre-fix):
      the gate was **not passed** and the blocker was isolated. Every
      directly observed Apple M4 / macOS 27
      run produced no banner, map print, probe log, or terminal
      marker in `vm-serial.log`; no `RC.TXT` is produced (good path,
      expected). The early-post-exit-crash hypothesis is **closed**: claim
      0009's NVRAM ladder showed the death was in the MMU-takeover window
      (`M2_MAPD!`), and claim 0010 (2026-08-07) root-caused and fixed it —
      the MMU takeover now **completes** on VZ (ladder reaches `M2_MMUP!`)
      and the serial probe runs to completion, selecting no device in the
      declared windows (`M2_SERIA`; claim 0013 later decoded those windows
      as Apple's efivars store + an internal debug UART and found the real
      console is a virtio-pci device outside them). The post-MMU access
      blocker (claims 0018/0020) was root-caused by claims 6460/7896
      (translation start-level mismatch + stale-TLB crutch) and fixed in
      production by claim 1517 (T0SZ=16 + TLBI at the switch); the serial
      gate now passes.
      Evidence: `artifacts/m2-mmu-takeover-gate.txt`, `artifacts/m2-firmware-regs.txt`,
      `artifacts/m2-table-walk.txt`, `artifacts/m2-mmu-bisect-tlbi.txt`.
      The console device itself is observed (claim 0013); its register
      layout stays `[inferred]` where RX is concerned until the RX path is
      driven.
- [x] Milestone two marker fallback gate (gate work item 3, claims
      0009/0010): **passing** (2026-08-07). Claim 0009's ladder
      discriminated the serial gate: every run ended at `M2_MAPD!` — the
      identity map was built but the post-install `M2_MMUP!` stage never
      appeared, so the kernel died in the MMU-takeover window and never
      reached the serial probe. Claim 0010 then **root-caused and fixed
      it**: the ladder now runs `M2_MAPD! → M2_MMUP! → M2_SERIA` — the MMU
      switch completes on VZ and the serial probe runs to completion,
      finding no device in the declared windows (later decoded as Apple's
      efivars store + an internal debug UART — claim 0013 — which also
      found the real console is a virtio-pci device outside them;
      evidence: `artifacts/m2-mmu-takeover-gate.txt`,
      `artifacts/m2-firmware-regs.txt`, `artifacts/m2-table-walk.txt`,
      `artifacts/m2-mmu-bisect-tlbi.txt`). The VZ serial gate's historical
      blocker (post-MMU access to the virtio-pci console transport) is
      resolved by claim 1517 (T0SZ=16 + TLBI at the switch); the gate now
      passes.
- [x] Milestone two bad-handoff failure gate: **passing** (fixed 2026-08-06,
      `agent/buffy/m2-badhandoff-fix`). Root cause was the naked `_start`
      shim's `bl kernel_main` overwriting the link register without
      saving/restoring the loader's `x30`, so the shim's final `ret` looped
      forever and the kernel never returned. After the two-instruction fix,
      `verify-bad-handoff.sh` exits 0 and `RC.TXT` shows
      `kernel_rc=0x0000000000000002`. Evidence:
      `artifacts/m2-badhandoff-fix-{before,after,gates,goodpath}.txt`.
- [x] M1.5 live RX / transcript gate (class B, claim 6684): **passing
      (2026-08-08)** — `bash tools/verify-live-transcript.sh` boots the
      production image, forwards scripted keystrokes (`help`/`version`/
      `mem`/`echo rx-live-ok`) into the guest's polled virtio receive
      queue after the takeover terminal state, and asserts the live
      `dipshit>` transcript in `vm-serial.log` — banner, echoed keystrokes,
      `available commands:`, `dipshit-kernel` version output, `mem:` map
      summary, and the `rx-live-ok` echo reply. 3/3 boots, byte-identical
      4421-byte transcripts. Evidence: `artifacts/live-transcript-*`
      (`live-transcript-gate.txt`, `live-transcript-report.txt`,
      `live-transcript-run-<NN>.txt`, `live-transcript-serial-<NN>.log`).

- [x] M1.5 live FAT32 storage gate (class B, claims 3475/6420):
      **passing (2026-08-09, upgraded to the real FAT driver by claim
      6420)** — `bash tools/verify-live-fs.sh` boots two VMs against the
      SAME disk image: run A (fresh image) drives `write hello.txt hello
      world` + `ls` + `cat hello.txt` and asserts the write-ok reply
      ("persisted .. bytes to FAT on the ESP"), the live volume listing
      (`EFI/`, `KERNEL.BIN`, `BOOTED.TXT`, `MEMMAP.TXT`, `LOADER.TXT`),
      `hello.txt` listed `[esp]`, and the cat reply; run B (fresh boot,
      same image) still lists `HELLO.TXT [esp]` (the FAT 8.3 short name)
      and prints the content — the file persisted through reboot **on the
      disk itself** via the virtio-blk transport (claim 3475's NVRAM
      persistence medium is replaced). 1/1 pair. Evidence:
      `artifacts/live-fs-*` (`live-fs-gate.txt`, `live-fs-report.txt`,
      `live-fs-run-<A|B>-<NN>.txt`, `live-fs-serial-<A|B>-<NN>.log`).

- [x] Milestone-three live gates (class B, claims 9187/5275/8215/3594/6120/
      5804/6729/6783/3200): **passing 2026-08-09/10** — live timer IRQ
      (claim 9187, 3/3, real periodic CNTP PPI 30 into the claim-9746 EL1
      IRQ vector), live tasks (claim 5275, tick-driven round-robin across
      real context switches), live EL0/SVC boundary (claim 8215, 1/1 —
      two sequenced pings prove return to EL0), live syscall-table gate
      (claim 3594, 1/1, exact snapshot `ping=2 write=3 yield=1 exit=1`),
      live uaccess (claim 6120, 1/1 — `valid=1 fault=1 recovered=1`: a
      real EL1 data abort during copy-in is recovered to EFAULT without
      crashing EL1), live address spaces (claim 5804, per-task TTBR0 with
      EL1-only kernel overlay), live lifecycle (claim 6729, spawn/exit/
      reap + idle reaper), live ESP exec (claim 6783, `USER.BIN` runs at
      EL0 from the ESP), and live blocking syscalls (claim 3200,
      sleep/wakeup in the tick scheduler). Full gate table:
      `docs/status.md`.

**Post-tag reverify (claim 7873, 2026-08-09):** the complete class A set
(just verify-portable: fmt, 95 + 110 unit tests, transcript gate, build,
image, inspect, swift runner build, context, coordination, coordination
tooling, mmu-debt) and the complete class B set (serial takeover
`zig build run`, bad-handoff, marker, nvram-console, host-console,
live-transcript, live-fs, live-timer, live-reboot, live-exceptions) were
re-run at the **`m1.5-interactive-monitor` tag (`74a51f3`, clean tree)**
— **all green**. Summary evidence:
`artifacts/gates-reverify-20260809-m15-tag.txt`.

**Milestone-three close-out reverify (claim 0707, 2026-08-10):** the
complete class A set (just verify-portable: fmt, unit tests,
test-console, build, image, inspect, swift runner build, context,
coordination, coordination tooling, mmu-debt — 11/11) and the complete
class B VZ set (serial takeover `zig build run`, bad-handoff, marker,
nvram-console, host-console, live-transcript, live-fs, live-timer,
live-tasks, live-userspace, live-svc, live-uaccess, live-addrspaces,
live-lifecycle, live-exec, live-sleep, live-reboot — 17/17) were re-run
at the milestone-three candidate HEAD `0c119d8` — **all green**; the
milestone is tagged **`m3-userspace`**. Evidence:
`artifacts/gates-reverify-20260810-m3-closeout.txt` +
`artifacts/classB-chunk{1,2,3,4}-m3-closeout.log`.

**Milestone-four close-out reverify (claim 2839, 2026-08-11):** the
complete class A set (fmt, unit tests, test-console, build, image,
inspect, swift runner build, context, coordination, coordination tooling,
mmu-debt — 11/11) and the complete class B VZ set (the full 28-gate
`verify-vz` aggregate: serial takeover `zig build run`, bad-handoff,
marker, nvram-console, host-console, live-transcript, live-fs, live-gfs,
live-timer, live-tasks, live-userspace, live-svc, live-uaccess,
live-addrspaces, live-lifecycle, live-exec, live-args, live-procs,
live-concurrent, live-long-lived, live-kill, live-sleep, live-entropy,
live-reboot, live-ipc, live-procs-syscall, live-scale, live-wait —
28/28) were re-run at the milestone-four candidate HEAD `9d7e4d5` on a
clean tree — **all green**; the milestone is tagged **`m4-processes`**.
Evidence: `artifacts/gates-reverify-20260811-m4-closeout.txt` +
`artifacts/m4-closeout-classA-1.log` + the per-gate `vz-live-*` logs.
