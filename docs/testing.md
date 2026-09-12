# VirelaiOS testing

> For the current state of each verification gate (pass/fail/blocked), see
> [`docs/status.md`](status.md). This file is the sequence and policy. The
> A/B/C/D classification is defined in
> [`docs/gate-inventory.md`](gate-inventory.md); the single generated
> inventory of every gate is
> [`docs/gate-fleet-inventory.md`](gate-fleet-inventory.md).

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

## Locale determinism

A generated file whose bytes depend on the shell's locale is worse than no
check at all: it passes for the author's shell and fails for everyone else's.
That is how the gate-fleet inventory drifted (issue #1177 — the tracked
render was the *byte* truncation under `LC_ALL=C` and the *character*
truncation under a UTF-8 locale, so `main` passed under UTF-8 and failed
under `C` with no workflow noticing). The rules that came out of it:

- **Committed generated files must render byte-identically under any
  locale.** `tools/inventory-gates.sh` writes the only tracked render
  (`docs/gate-fleet-inventory.md`); it pins `LC_ALL=C` for the render,
  truncates headers in UTF-8 **characters** rather than bytes, and its
  `--check` mode renders a second copy under `en_US.UTF-8` and fails when
  the two disagree — so a locale-sensitive operation cannot creep back in.
  (Reachability: 51 of the 210 `tools/gate/specs/*.spec` files contain
  non-ASCII; **2** of their first-line headers do —
  `live-m21-persist-title-orphan` (em dash) and `live-wnd5-gate2-policy`
  (en dash). Only the first crosses its truncation boundary, which is why
  exactly one row differed.)
- **Pin `LC_ALL=C` wherever the output is compared, committed, or used to
  name an artifact.** `cut -c`, `printf '%.Ns'` and bash `${v:0:N}` count
  bytes or characters depending on the locale, and `sort`/`uniq` collation
  plus the `[:lower:]`/`[:upper:]` tables are locale-dependent. Count
  characters explicitly when truncating human-authored text.
- **Audit (issue #1186):** these constructs appear nowhere else under
  `tools/` except `tools/verify-zc-corpus.sh` — its case-list dedupe and
  its case-name to artifact-name mapping are now pinned — and the remaining
  unpinned `sort -u` calls (`tools/verify-pointer-manual.sh`,
  `tools/probe-pointer-routes.sh`) feed a count or a diagnostic string in
  class C/D gates, never a tracked byte or a compared filename.

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
    exact banner `VirelaiOS kernel has seized control.`, a
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
    `VirelaiM2`, and the runner saves the ordered ladder to
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
17. Verify the multiagent coordination surface (claims as GitHub issues):
    `bash tools/status/verify-issue-coordination.sh` (also `just
    verify-coordination` and CI). Fetches the open issues labeled `claim`
    via `gh` and fails when two of them from different branches declare
    overlapping `- **Touches:**` files (one editor per file), or when an
    open claim has no Owner line with a backticked branch; claims with no
    comment/edit for 14+ days draw a warning. The old file-based tracker
    (`docs/claims/` + `docs/logs/`, deterministic IDs, generated indexes,
    the indexes-bot workflow) was deleted 2026-09-03.
18. Test the coordination tooling itself: `bash
    tools/status/test-coordination.sh` (also `just test-coordination` and
    CI) — positive/negative offline fixtures for the issue gate's parsing,
    overlap detection (exact + prefix-glob), blocked-claim exclusion,
    staleness warnings, the empty-tracker case, the weekly staleness sweep
    (`tools/status/sweep-stale-claims.sh` — detection plus its `claim:stale`
    label decisions: flag once per stale period, skip already-flagged
    claims, unlabel on fresh updates), and the real-time unlabel guard
    (`tools/status/unlabel-guard.sh` — the bot-vs-human decision the
    event-driven `unlabel-fresh` job runs, exercised against issue_comment /
    issues webhook payloads: human comments/edits unlabel, while the sweep's
    own warning comments and bot-driven events never do). All fixtures run
    in a throwaway sandbox with no network. The GitHub Actions workflow
    files are also linted with actionlint (`bash tools/lint-workflows.sh`,
    class A) so trigger/expression typos fail in CI instead of only
    surfacing when a workflow runs for real. The real-time path can
    additionally be rehearsed LIVE (manual): `just rehearse-unlabel`, or
    the `workflow_dispatch` of `.github/workflows/claim-rehearsal.yml`,
    creates a throwaway claim issue, marks it `claim:stale`, and verifies a
    real event removes the label before cleaning up. The full event cascade
    needs a human-scoped actor (a local collaborator's gh login, or the
    `CLAIM_REHEARSAL_TOKEN` PAT secret in CI — GITHUB_TOKEN events do not
    spawn further runs); without one the guard's live branch is exercised
    in-process against the throwaway issue.
19. Run the live RX / transcript gate (class B, claim 6684):
    `bash tools/verify-live-transcript.sh` (also `just
    verify-live-transcript`) — boots the production image, forwards
    scripted keystrokes (`help`/`version`/`mem`/`echo`) into the guest's
    virtio receive queue after the takeover, and asserts the live
    `virelai>` transcript (banner, echoed commands, command output, echo
    reply) in `vm-serial.log`. **Passing 2026-08-08** (3/3 boots,
    byte-identical transcripts; evidence `artifacts/live-transcript-*`).

> The full class-A (portable, no-VM) gate set runs as `just verify-portable`
> (legacy alias `just verify`) and in CI (`.github/workflows/ci.yml`).
> **CI proves only this class** — a green badge says nothing about the
> Apple-silicon VZ hardware gates (class B).
>
> **Host prerequisites (class B):** the Go-runtime gates (`go-hello`,
> `go-args`) are NOT hermetic — they exec `.build/go/GOHELLO.ELF` +
> `.build/go/GOARGS.ELF`, and refuse to run (honestly, with the build
> hint) until `just go-toolchain` has provisioned this machine (it builds
> BOTH fixtures). The recipe is idempotent; the first run takes several
> minutes (one Go make.bash pass — the cross-std pass is phase-2 opt-in
> via `GOVIRELAI_STD=1`). Do not auto-build the fork inside a gate
> (rejected in review — see `tools/go/README.md`).
>
> The class-B fleet is **discovered, not listed** (M40 GF5, issue #940):
> every `tools/gate/specs/*.spec` plus the four legacy class-B scripts
> (`bad-handoff`, `marker`, `nvram-console`, `host-console`), exactly as
> `bash tools/gate/fleet.sh list` prints. Run one with `just gate <id>`, a
> pattern group with `just gates <pattern>`, the whole fleet with
> `just verify-vz` (Apple silicon only — each member boots VZ VMs; the
> interactive serial-takeover gate `zig build run` needs a TTY and is run
> with `just run`). The same list shards
> `.github/workflows/vz-gates.yml` on a registered macOS 27+ Apple silicon
> runner. The class-D diagnostics run individually per claim. See
> [`docs/gate-fleet-inventory.md`](gate-fleet-inventory.md) for the full
> per-member table.
>
> **Permanent rule (M40 GF6, issue #931):** new gates are specs under
> `tools/gate/specs/` — never new `tools/verify-*.sh` scripts (rejected in
> review); the generated inventory fails CI (`--check`) on any unregistered
> gate. Full-fleet reference wall time: 10,052 s serial (185 members, M40
> GF6 reference host, 2026-09-06).
>
> **Dev-shell PATH note (the one canonical paragraph):** fleet members and
> CI need the modern Homebrew toolchain — `/opt/homebrew/bin` FIRST and
> `/opt/homebrew/opt/gnu-sed/libexec/gnubin` for GNU sed, byte-for-byte
> what both workflows set up. Locally, `source tools/env-check.sh` (or
> `just check-env`) verifies the same thing and complains loudly when the
> 2007-era system bash/sed win instead.

## Gate fleet (M40 GF1–GF5, issues #934–#940)

- **No new `tools/verify-*.sh` files.** New gates arrive as vgate specs
  (`tools/gate/SPEC.md`); one-off per-gate boot scripts are rejected in
  review.
- **The spec dir is the single source of truth.** `tools/gate/fleet.sh`
  discovers the class-B fleet (specs + the four legacy class-B scripts);
  the `just gate`/`just gates`/`just verify-vz` recipes, the
  `vz-gates.yml` CI shards, and the fleet section of
  `docs/gate-fleet-inventory.md` are all derived from that discovery —
  adding a spec registers it everywhere with zero list edits.
- **The fleet inventory is generated, not written:**
  `bash tools/inventory-gates.sh` rewrites `docs/gate-fleet-inventory.md`
  (also `just inventory-gates`); `just inventory-gates --check` fails when
  the tracked report drifts from a fresh render — every added, removed, or
  renamed spec or script under `tools/` must ship with a regenerated report.
  This bullet used to say "and CI runs that check (GF5)", which was not
  true: the macos CI job never ran it. Issue #1186 added the step (plus two
  other portable gates that job had silently dropped), and
  `tools/lint-workflows.sh` now asserts that every command in the
  `just verify-portable` recipe appears in `.github/workflows/ci.yml`, so a
  portable gate cannot go local-only again without failing that lint.
- `docs/gate-inventory.md` defines the class A/B/C/D policy only; the
  archive detail file (`docs/archive/gate-inventory-detail.md`) is frozen
  historical evidence — nothing reads its `GATE_INVENTORY` block anymore.

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Kernel serial probe, exact banner, map hex view, and terminal marker |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM; holds the `VirelaiM2` marker ladder after a marker-gate run |
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
      `virelai>` transcript in `vm-serial.log` — banner, echoed keystrokes,
      `available commands:`, `virelai-kernel` version output, `mem:` map
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
