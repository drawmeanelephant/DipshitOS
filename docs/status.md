# VirelaiOS — status

> **Host identity:** Apple silicon running macOS 27 or newer only, hosted by
> Apple's Virtualization.framework; **not Linux, not Unix, not QEMU**
> (`AGENTS.md`). The runner enforces the macOS 27+ floor at runtime.

> Living status tracker. **Claims are GitHub issues labeled `claim`** (see
> [Multiagent coordination](#multiagent-coordination)), not repo files. Keep
> this file a compact table: per-card detail lives on the issue and its
> `docs/march-m*.md` tracker, not here. Gates are the evidence — **observed**
> (saved gate output / CI) versus **inferred** (reasoning only). The
> pre-compaction text (the M17–M51 gate-by-gate narrative, 2026-09-12,
> 687 lines) is preserved in git history at `e5480c9`.

## Milestones

All milestones through M51 are complete. Closed-milestone detail is under
`docs/archive/` and in the per-arc `docs/march-m*.md` trackers; open cards, if
any, are on the GitHub tracker.

| # | Milestone | What it proved | Status |
|---|-----------|----------------|--------|
| 0 | Boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware (`\BOOTED.TXT`) | ✅ |
| 1 | Kernel handoff | `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`kernel_rc=0x0`); ADR 0002 | ✅ |
| 2 | Kernel proper | `ExitBootServices`, captured EFI map, identity TTBR0_EL1 tables, MMIO serial + polled TX console; ADR 0004 | ✅ 2026-08-08 |
| 1.5 | Interactive Kernel Monitor | Live interactive serial console (TX+RX); tag `m1.5-interactive-monitor` | ✅ 2026-08-09 |
| 3 | Allocator, interrupts, tasks | Physical allocator, GIC+timer, tasks, EL0/SVC, syscall ABI 0–4, uaccess, per-task TTBR0, ESP exec, sleep | ✅ 2026-08-10 |
| 4 | Real randomness | Virtio entropy + ChaCha20 CSPRNG, ASLR, DATA partition, process abstraction | ✅ 2026-08-11 |
| 5 | Networking | Virtio-net TX/RX, ARP, IPv4, UDP, NAT, DHCP, TCP + retransmission | ✅ 2026-08-12 |
| 6 | Graphics | Virtio-gpu (1280×720), text, Road Pops, Driving Award WM, draw syscalls 12–15 | ✅ 2026-08-13 |
| 7 | Input | Apple XHCI + HID keyboard/pointer, event FIFO → line editor | ✅ 2026-08-13 |
| 8 | Usability (ADR 0008) | Grouped help, line editor/history, error contract, HIG, motd/about/sysinfo/settings | ✅ 2026-08-15 |
| 9 | App events (ADR 0009) | Per-process event queues, `sys_poll_event`/`sys_wait_event`, KEYTEST.BIN | ✅ 2026-08-15 |
| 10 | Userland FS (ADR 0010) | Per-process file table, path canon, slots 23–27, SAVETEXT/TYPE/DIR.BIN | ✅ 2026-08-15 |
| 11 | Desktop (ADR 0011) | Toolkit ui.zig/font8x8, CALC/NOTEPAD/TOP/DESKTOP.BIN | ✅ 2026-08-16 |
| 12 | Net apps (ADR 0012) | TCP slots 30–33, DNS, FETCH/CHAT.BIN | ✅ 2026-08-16 |
| 13 | Files & apps | Mutating FS (delete/rename/truncate), APPS.TXT manifest, FILE.BIN | ✅ 2026-08-16 |
| 14 | Shared services | Clipboard, app timers, NOTEPAD composition, hardening | ✅ 2026-08-18 |
| 15 | Audio | Virtio-snd (DID 0x1059), PCM playback, `sys_audio` 42–45, JINGLE/CHIME.BIN | ✅ 2026-08-18 |
| 16 | Kernel grows up | DSK3 segmented image, guard pages, grown pools | ✅ 2026-08-19 |
| 17 | Desktop completeness | C1–C10 + Arc1–5: widget depth, window management, app upgrades, polish | ✅ 2026-08-21 |
| 18 | Terminal & shell depth | T1–T16: scrollback, selection, search, persistent history, colors, scripting | ✅ 2026-08-24 |
| 19 | Shell programming | P1–P16: pipes (56/57), redirection, env, functions, substitution, arithmetic, conditionals | ✅ 2026-08-24 |
| 20 | Text & Unicode | U1–U5: font sizes, Unicode glyphs, search, chrome, tabs | ✅ 2026-08-23 |
| 21 | Window depth | W1–W16: tiling, minimize, alt-tab, notification center, maximize, focus rings | ✅ 2026-08-26 |
| 22 | Developer tools | D1–D16: ELF loader, assembler, symbols, disassembler, strace, ps, dmesg | ✅ 2026-08-25 |
| 23 | The text editor | E1–E25: EDIT.BIN, undo/redo, goto, tabs, syntax, console split | ✅ 2026-08-26 |
| 24 | CALC grows up | K1–K16: programmer mode, memory, units, constants, history | ✅ 2026-08-23 |
| 25 | File manager depth | F1–F18: du, sort, overwrite/conflict, path copy | ✅ 2026-08-26 |
| 26 | Network experience | N1–N16: ping, netstat, traceroute, HTTP fetch display, download mgr | ✅ 2026-08-26 |
| 27 | Desktop polish | G1–G30: splash, wizard, previews, sounds, sysmon, tooltips, audits | ✅ 2026-08-27 |
| 28 | SMP | PSCI CPU_ON bringup, per-core schedulers, spinlocks, GICv3 SGI IPIs | ✅ 2026-08-27 |
| 29 | VM depth | Demand paging, COW page sharing, anonymous mmap, zero-leak teardown | ✅ 2026-08-27 |
| 30 | Dynamic linking | Freestanding `LD.SO`, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture | ✅ 2026-08-27 |
| 31 | Dyn-linking ecosystem | CALC/NOTEPAD/FILE/DESKTOP → `.ELF`, runtime `dlopen`/`dlsym` | ✅ 2026-08-27 |
| 32 | WM server migration | Seam A: desktop policy to a userland WM server (slot 65), kernel slimmed WMS1–WMS9 | ✅ 2026-08-30 |
| 33 | Seam B | Full pixel ownership: shared-anon mmap, apps own buffers, WM composes one present | ✅ 2026-08-31 |
| 34 | FAT-free storage | Host file channel HF1–HF7 (macOS share over custom-virtio); FAT removed; CLONE dedup | ✅ 2026-09-02 |
| 35 | WASM core interpreter | `WASM.BIN` interpreter, frozen `env.*` surface, `wc` capstone | ✅ 2026-09-02 |
| 37 | Desktop quality pass | God Menu overlay, tab strip render + mouse, design tokens, snap guides | ✅ 2026-09-03 |
| 38 | Vector typography | TrueType Inter/Fira Code, anti-aliased BGRA blending, proportional metrics | ✅ 2026-09-03 |
| 39 | Tabbed desktop & modular UI | Modular `ui.zig`, rounded rects, `TABWM.BIN`, tab lifecycle, viewports | ✅ 2026-09-04 |
| 41 | Test separation | Parallel `zig build test`, shared mocks, de-monolithized source | ✅ 2026-09-04 |
| 42 | The Sexiburger desktop | Mascot raster, WM→app resize seam, `lib/tabapp.zig`, full-viewport, UX hardening round 2 | ✅ 2026-09-05 |
| 43 | Device depth (USB) | XHCI bulk engine, USB mass storage (BOT+SCSI), `.usb` block seam, lifecycle | ✅ 2026-09-10 |
| 44 | Terminal (vt) seam | `/dev/tty` device file, ADR 0007 slot 67 `sys_tty_attach`, `TTYECHO.BIN`; ADR 0020 | ✅ 2026-09-11 |
| 45 | Userland shell & front-ends | `tty.zig` editor, `SH.BIN`, `TERM.BIN`, net front-end, default-shell flip; ADR 0021 | ✅ 2026-09-11 |
| 46 | Remote access Stage 0/1 | `--console-tcp`, guest net auth, RC0–RC4; ADR 0022 | ✅ 2026-09-11 |
| 47 | Crypto primitives | SHA-256/512, HMAC, ChaCha20, Ed25519; ADR 0023 | ✅ 2026-09-11 |
| 48 | Browser-style tab depth | Rail-native tabs: reopen/duplicate, reorder, pin/group, start surface, per-tab history, preview (umbrella #1120) | ✅ 2026-09-10 |
| 49 | A shell I'd use daily | `monitor` detach, startup contract, `toolbox.zig` multicall, editing ergonomics | ✅ 2026-09-11 |
| 50 | Trust & isolation | uid/caps, permissions, secrets, authenticated remote, privilege gating; ADR 0024 | ✅ 2026-09-11 |
| 51 | SSH | Userland SSH-2 client `SSH.BIN`; real-OpenSSH interop; ADR 0025 | ✅ 2026-09-12 |

> M40 (the gate-fleet consolidation, issue #934, done 2026-09-06) was a tooling
> workstream, not a product milestone; M36 was skipped.

## Open work

The only threads not closed:

| Thread | State / next step | Cards |
|--------|-------------------|-------|
| **M-web — in-guest HTML renderer (`DOC.BIN`)** | S1 merged (#1222); S2 tables PR #1223; S3–S6 (img/nav/fetch/publish) stacked as one gated PR | #1200, #1201 |
| **Go runtime port — `GOOS=virelai`** | Phase 0a merged (PR #1187); phase 0b round 2 in flight — threads/futex landed per ADR 0027 (slots 73/74, `go-goroutines` gate PASS with the cross-core proof), every `proc.go` delta retired, and the argv boot flake root-caused (ASLR band vs the ~1.2 GiB sbrk heap; `sys_mmap` collision refusal is the backstop). Next: envp half, then 0c fault delivery | #1163, #1194, #1214 |

## Gate status

> All class-A (portable) and class-B (VZ hardware) gates are green at HEAD.
> Gate classes are defined in [`docs/gate-inventory.md`](gate-inventory.md).
> Since M40 the class-B fleet is **discovered** from `tools/gate/specs/` via
> `tools/gate/fleet.sh`; the generated inventory is
> [`gate-fleet-inventory.md`](gate-fleet-inventory.md) (`--check` enforced in CI).

| Gate | Command | Result |
|------|---------|--------|
| Format | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | ✅ |
| Guest build | `zig build` | ✅ |
| Disk image | `zig build image` | ✅ |
| Binary + image inspect | `zig build inspect` | ✅ |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ |
| Context snapshot | `zig build context` | ✅ |
| Unit tests | `zig build test` (parallel; 2,260+ host tests) | ✅ |
| Class-A portable set | `just verify-portable` | ✅ |
| Class-B VZ fleet | `just verify-vz` (sharded ×4 in CI; needs repo var `VZ_RUNNER_LABEL`) | ✅ on the reference host |
| Coordination gate | `just verify-coordination` + `just test-coordination` | ✅ |

Per-gate evidence lives in the run logs / CI. Verbose per-gate notes (M3-era
shim ladder, NVRAM console, custom-virtio, the M5 net sweep, …) are in git
history at `e5480c9`.

> Legacy M2/M20/M22/M34 scripts that are **manual-only** (not in the fleet, CI,
> or `just`; run by hand if ever needed) — candidates for deletion:
> `audit-vz-irq-api.sh`, `check-zc-host-contract.py`, `probe-pointer-routes.sh`,
> `test-unicode-torture.sh`, `verify-custom-virtio.sh`, `verify-cvc-echo.sh`,
> `verify-fw-mmu-capture.sh`, `verify-pointer-manual.sh`,
> `verify-t0sz16-walkprobe.sh`, `verify-t0sz16.sh`, `verify-transcript.sh`,
> `verify-tx-transition.sh`, `verify-zc-corpus.sh`.

## Assumptions & gaps (checked against merged `main`)

- **ADR 0004 console:** polled TX-only virtio-pci (DID 0x1043, BAR 0x100010000; RX followed).
- **Runner serial input:** `VZFileHandleSerialPortAttachment(nil)`; `--console` wires stdin (M1.5).
- **Memory:** `memorySize = 256 MiB`; `mem` derives from the captured map.
- **Kernel is post-`ExitBootServices` and never returns** (handoff v2 in x3, ends in a WFE loop).
- **Firmware quirks:** `ConOut` is not routed to virtio; the kernel drives the console itself. See `hardware-contract.md`.

## Multiagent coordination

Claims are **GitHub issues labeled `claim`** — one issue per piece of work,
filed before code is written. Binding rules (mirrored in `AGENTS.md`):

1. **The card IS the claim.** Claim an existing card in place
   (`just claim-card <issue>`); file a new issue only when there is no card.
   An OPEN `claim` issue is an ACTIVE claim — another agent will not duplicate
   it. The landing PR says `Closes #<claim>` so merge closes it.
2. **One editor per file at a time.** Declare every path/glob in the machine-read
   `Touches` bullet. The gate fails when two open claims from different branches
   declare overlapping `Touches` (generated artifacts are exempt).
3. **Progress and completion live on the issue.** Append comments (never rewrite
   earlier ones); close with a final evidence comment when the work lands or is
   abandoned.
4. **Heartbeats.** A comment/edit keeps a claim alive; 14+ days of silence draws
   a gate warning, ~21+ days and anyone may close it.
5. **Evidence is the gate run**, not a committed log (see `AGENTS.md`).
6. **The gate:** `bash tools/status/verify-issue-coordination.sh`
   (`just verify-coordination`, also CI) reads open `claim` issues via `gh` and
   fails on `Touches` overlaps; `bash tools/status/test-coordination.sh`
   (`just test-coordination`) tests the tooling offline.

The old file-based tracker (`docs/claims/` + `docs/logs/`) was deleted
2026-09-03; old four-digit claim numbers in prose are git-history references.

## Housekeeping conventions

- **This file is the single source of truth** for status, and stays a compact
  table. Per-card detail goes on the issue; per-arc detail goes in one
  `docs/march-m*.md` or ADR.
- **Evidence under `artifacts/`** (gitignored). No evidence ⇒ not observed.
- **Facts vs inference:** hypotheses are tagged `(inferred)`; hardware tags flip
  only with saved logs.
- **Branch hygiene:** `agent/...` branches → PR against `main` (ADR 0003).
- **New gates are declarative specs** under `tools/gate/specs/` (never a new
  `verify-*.sh`); extend an existing spec when it already covers the change.

## Related docs

- [`AGENTS.md`](../AGENTS.md) — project rules.
- [`testing.md`](testing.md) — verification sequence & evidence policy.
- [`hardware-contract.md`](hardware-contract.md) — hardware `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components & data flow.
- [`gate-inventory.md`](gate-inventory.md) · [`gate-fleet-inventory.md`](gate-fleet-inventory.md) — gate classes; generated fleet inventory.
- [`archive/`](archive/) — closed-milestone detail (`status-m*-detail.md`), frozen designs, one-shots.
- Per-milestone trackers: `docs/march-m*.md`.
- Claims: `gh issue list --label claim --state open`.
