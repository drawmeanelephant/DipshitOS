# DipshitOS living status, goals & changelog

> **Host identity:** Apple silicon running macOS 27 or newer only — hosted by
> Apple's Virtualization.framework; **not Linux, not Unix, not QEMU** (see
> `AGENTS.md`). The runner enforces the floor at runtime (macOS 27+).

> This file is the project's **living status tracker** and its **multiagent
> coordination surface**: where we are, what we are trying to build next, how
> far along each step is, **who currently claims which piece of work**, and
> pointers to the append-only per-branch changelog. Claims and logs are
> sharded (see [Multiagent coordination](#multiagent-coordination)) so
> parallel agents never collide on one file. Update it as work lands —
> flip the checkboxes, fill in the notes, and **append** to your branch's
> log under `docs/logs/`.
> Claims stay honest per `AGENTS.md`: **observed** (log evidence under
> `artifacts/`) versus **inferred** (reasoning/docs only).

> **Premise check (2026-08-06):** this tracker was first frozen against the
> milestone-one-era `main`. On the same day, PRs #6/#7 merged the
> **milestone-two kernel proper** (ADR 0004), which changed the premises
> below: the kernel now calls `ExitBootServices`, owns an identity-map MMU,
> drives a polled TX-only MMIO serial console, and never returns. This file
> was refreshed accordingly — the plan's shape is kept, its factual anchors
> are reconciled with the merged state. PR #10 later unified this tracker
> with the milestone-two gate evidence and added the multiagent changelog
> (now sharded per branch under [docs/logs/](logs/README.md); see the
> [Changelog](#changelog-append-only-per-branch)).

## Current position

| Milestone | What it proved / is | Status |
|-----------|---------------------|--------|
| Zero — boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware; output observed on host (`\BOOTED.TXT`) | ✅ done |
| One — kernel handoff | Separate freestanding `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`\RC.TXT` = `kernel_rc=0x0`); ADR 0002 | ✅ done |
| Two — kernel proper | ExitBootServices, captured EFI map, identity TTBR0_EL1 tables, MMIO serial probe + polled TX console (ADR 0004) | ✅ **gates passed 2026-08-08** (claim 1517) |
| **1.5 — Interactive Kernel Monitor ("Dipshit Monitor")** | Live interactive monitor on serial console (TX+RX live) | ✅ **done 2026-08-09** (claim 3475/6420, tag `m1.5-interactive-monitor`, 7/7 gates) |
| Three — allocator, interrupts, tasks | Physical allocator, GIC + timer, tasks, EL0/SVC, syscall ABI (0–4), uaccess, per-task TTBR0, lifecycle, ESP exec, sleep | ✅ done 2026-08-10 (claim 0707, tag `m3-userspace`) |
| Four — real randomness | Virtio entropy (DID 0x1044) + ChaCha20 CSPRNG, ASLR, general DATA partition, process abstraction (concurrent/long-lived follows) | ✅ done 2026-08-11 (claim 2839, tag `m4-processes`) |
| Five — networking | Virtio-net TX/RX, ARP, IPv4, UDP, NAT, DHCP, TCP + retransmission (N1–N11) | ✅ done 2026-08-12 (claim 5357) |
| Six — graphics: Driving Award + Road Pops | Virtio-gpu (DID 0x1050, 1280×720 B8G8R8X8), text, Road Pops tee, Driving Award WM, draw syscalls 12–15 | ✅ done 2026-08-13 (claim 0487, G1–G6) |
| Seven — input: USB XHCI + HID | Apple XHCI (VID 0x106b/DID 0x1a06), HID keyboard+pointer, event FIFO → line editor | ✅ done 2026-08-13 (claim 6050, I1–I3) |
| Eight — usability (ADR 0008) | Grouped help, line-editor/history, error contract, window HIG, motd/about/sysinfo/settings | ✅ done 2026-08-15 (claim 2649, U0–U8) |
| Nine — app events (ADR 0009) | Per-process event queues, sys_poll_event (21)/sys_wait_event (22), KEYTEST.BIN | ✅ done 2026-08-15 (claim 9328, E0–E6) |
| Ten — userland FS (ADR 0010) | Per-process file table (8 handles), path canon, slots 23–27, SAVETEXT/TYPE/DIR.BIN | ✅ done 2026-08-15 (claim 0510, F0–F4) |
| Eleven — desktop (ADR 0011) | Toolkit ui.zig/font8x8, CALC/NOTEPAD/TOP/DESKTOP.BIN (sys_exec 28, sys_kill 29) | ✅ done 2026-08-16 (claim 2427, A0–A5) |
| Twelve — net apps (ADR 0012) | TCP slots 30–33, DNS, FETCH/CHAT.BIN | ✅ done 2026-08-16 (claim 5416, N0–N3) |
| Thirteen — files & apps (slots 34–37) | Mutating FS (delete/rename/truncate), APPS.TXT manifest, FILE.BIN, manifest desktop | ✅ done 2026-08-16 (claims 5801/8877/4742/4046, B1–B4) |
| Fourteen — shared services | Clipboard (38–39), app timers (40–41), NOTEPAD composition, hardening (S4) | ✅ done 2026-08-18 (claims 0169/7323/3289/4482, S1–S4) |
| Fifteen — audio | Virtio-snd (DID 0x1059), PCM playback, sys_audio 42–45, JINGLE/CHIME.BIN, volume/mute | ✅ done 2026-08-18 (claim 3206, A1–A4) |
| Sixteen — kernel grows up | DSK3 segmented image + data/BSS, guard pages (139), grown pools (tasks 11/processes 16/tables 512), composition | ✅ done 2026-08-19 (claims 3805/8403/0339/2714, C1–C4) |
| Seventeen — desktop completeness | C1–C10 + Arc1–5: widget depth, window management, app upgrades, rich interactions, system polish | ✅ done 2026-08-21 (GH milestones 1–5) |
| Eighteen — terminal & shell depth | T1–T16: scrollback, selection, search, persistent history, colors, scripting mode | ✅ done 2026-08-24 (GH milestone 6) |
| Nineteen — shell programming | P1–P16: pipes (slots 56/57), redirection, env vars, functions + args, substitution, arithmetic, conditionals | ✅ done 2026-08-24 (GH milestone 7) |
| Twenty — text & Unicode | U1–U5: font sizes, Unicode glyphs, search, chrome, tabs | ✅ done 2026-08-23 (GH milestone 8) |
| Twenty-one — window depth | W1–W16: tiling, master-detail, minimize, alt-tab, notification center, maximize, focus rings | ✅ done 2026-08-26 (claim 1306, GH milestone 9) |
| Twenty-two — developer tools | D1–D16: ELF loader, assembler, symbols, disassembler, strace, ps, dmesg, sysinfo, dev console | ✅ done 2026-08-25 (GH milestone 10) |
| Twenty-three — the text editor | E1–E25: EDIT.BIN, undo/redo, goto, tabs, syntax, console split | ✅ done 2026-08-26 (GH milestone 11) |
| Twenty-four — CALC grows up | K1–K16: programmer mode, memory, units, constants, history persist | ✅ done 2026-08-23 (GH milestone 12) |
| Twenty-five — file manager depth | F1–F18: du, sort, overwrite/conflict, path copy, … — 5/5 live gates on VZ | ✅ done 2026-08-26 (GH milestone 13) |
| Twenty-six — network experience | N1–N16: ping, netstat, traceroute, HTTP fetch display, download mgr, net profile, offline preflight | ✅ done 2026-08-26 (GH milestone 14; N13/N14 closed out 2026-08-28, claim 8852) |
| Twenty-seven — desktop polish | G1–G30 = issues #444–#473: splash, wizard, about, previews, sounds, sysmon, tooltips, audits, dogfood | ✅ done 2026-08-27 (GH milestone 15) |
| Twenty-eight — SMP | PSCI CPU_ON bringup of core 1, per-core schedulers, spinlocks, GICv3 SGI IPIs | ✅ done 2026-08-27 (issue #595, claim 6438, PR #611) |
| Twenty-nine — VM depth | Demand paging, COW page sharing, anonymous mmap (slots 63/64), zero-leak teardown | ✅ done 2026-08-27 (issue #598, claim 8247) |
| Thirty — dynamic linking | Freestanding `LD.SO` linker, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture, live gate | ✅ done 2026-08-27 (issue #599, claim 7921) |
| Thirty-one — dyn linking ecosystem | CALC/NOTEPAD/FILE/DESKTOP → `.ELF`, runtime `dlopen`/`dlsym` | ✅ done 2026-08-27 (issue #602, claim 4001) |

> **Narratives for M3–M16** are archived per milestone under `docs/archive/status-m{N}-detail.md` (issue #262).
> Each archive preserves the verbatim pre-compression table row plus march/claim pointers; the live table above is the one-line summary.
> Per-milestone detail trackers: `docs/march-m*.md`; the completed milestones' roadmap plans are archived under `docs/archive/roadmap-m{N}.md` (issue #264).

Resolved loose end: the milestone-one `KERNEL.TXT` corruption is **fixed**
(ADR 0002 — the loader now places image content at `base+0`; the write is
byte-perfect and gated by `zig build run`).

## Gate status

> All class-A (portable) and class-B (VZ hardware) gates are green at HEAD.
> Full re-verification history (57 lines of per-candidate close-out notes for M3–M16) is archived in git
> (`docs/status.md` @ `aa4f111`, `artifacts/gates-reverify-*.txt`). The live gate table below is the contract;
> `docs/gate-inventory.md` defines classes (A portable, B VZ, C interactive, D diagnostic).

| Gate | Command | Result | Last evidence |
|------|---------|--------|---------------|
| Format | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Guest build | `zig build` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| VZ hardware gates in CI | `.github/workflows/vz-gates.yml` — all class-B gates sharded ×4 on a self-hosted macOS 27+ runner, aggregate **VZ hardware gates** context required by branch protection | 🔶 wired / skipped until enforced | 2026-08-25: SKIPPED honestly until repo variable `VZ_RUNNER_LABEL` names a registered runner — registration steps in `docs/vz-runner.md`; hosted runners top out at macOS 26, below the project's documented floor |
| Disk image | `zig build image` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Binary + image inspect | `zig build inspect` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| Context snapshot | `zig build context` | ✅ pass | re-run 2026-08-08 (preflight); re-verified at `076ddf1` (claim 8073) |
| **VZ serial gate** | `zig build run` | ✅ **PASS 2026-08-08** | banner `DipshitOS kernel has seized control.` + `memory-map descriptors=0x…` + `kernel terminal state` in `vm-serial.log` (claim 1517; artifacts under `artifacts/`). **Re-verified live at `076ddf1` (claim 8073):** banner + 27-descriptor map (`key=0x2c4`) + `dipshit>` prompt in `artifacts/vm-serial.log`, runner exit 0. **Re-verified live at `706712c` (claim 2233):** banner + 27-descriptor map (`key=0x2d4`) + `dipshit>` prompt, runner exit 0. **Re-verified live at `a3644cf` (claim 0658):** banner + 27-descriptor map (`key=0x2c4`) + `dipshit>` prompt, runner exit 0. Root cause was the translation start-level mismatch (claims 6460/7896); fixed in production with T0SZ=16 + `tlbi vmalle1` at the switch. Historical blocker detail (claims 0013/0018/0020): console is a virtio-pci device (bus 0 D5 `0x1af4/0x1043`), transport armed pre-exit, first post-switch BAR/common-config read did not return |
| **Live transcript / RX gate** | `bash tools/verify-live-transcript.sh` | ✅ **PASS 2026-08-08** | host scripted keystrokes reach the kernel end to end through the polled virtio receive queue and the live `dipshit>` transcript is asserted in `vm-serial.log` (claim 6684, 3/3 boots; artifacts `live-transcript-*`) |
| **Live exception-vector gate** | `bash tools/verify-live-exceptions.sh` | ✅ **PASS 2026-08-08** | VBAR_EL1 vectors installed; `dipshit> fault` triggers a real synchronous exception (`udf`) that the handler reports (`[EXC] sync from EL1t`, `ec=0x00 unknown-reason`, ESR/FAR/ELR/SPSR) and resumes — shell continues (`fault: handled, resumed after faulting instruction` → follow-up `echo` reply), 2/2 boots (claim 9746; artifacts `live-exceptions-*`) |
| **Live tasks scheduler gate** | `bash tools/verify-live-tasks.sh` | ✅ **PASS 2026-08-09** | tick-driven round-robin (claim 5275): the timer PPI preempts the shell, the worker advances (report line `tasks worker advances=N`, N≥1 — only possible after ≥ 2 real context switches), and the shell resumes to run commands (`rx-tasks-ok`); `tasks` command reports both tasks; artifacts `live-tasks-*` |
| **Live EL0/SVC boundary gate** | `bash tools/verify-live-userspace.sh` | ✅ **PASS 2026-08-10** | claim 8215 regression: two sequenced pings prove return to EL0; the payload waits for a timer-only witness before cooperative yield, and the shell-side evidence follows real timer preemption |
| **Live syscall-table gate** | `bash tools/verify-live-svc.sh` | ✅ **PASS 2026-08-10** | claim 3594, 1/1 (re-verified under claim 6120 with `write=3`): three EL0 writes (good line, bad-pointer EFAULT exercise, marker line), timer IRQ before yield/exit; exact single snapshot `ping=2`, `write=3`, `yield=1`, `exit=1`; non-returning status-7 exit and one post-exit `rx-svc-ok` reply. |
| **Live uaccess gate** | `bash tools/verify-live-uaccess.sh` | ✅ **PASS 2026-08-10** | claim 6120, 1/1: EL0 passes an unmapped bad pointer (`0x1_2000_0000`, above the identity blanket) to `sys_write`, receives `-3`/EFAULT, and survives to write `uaccess: efault ok n=8`; the `uaccess` monitor command runs a validated copy (`valid=1`) and a raw copy from an unmapped address that takes a **real EL1 data abort, recovered** (`recovered=1`, `fault=1`, no `[EXC] parking`), and the shell answers `rx-uaccess-ok`. |
| **Live ESP exec gate** | `bash tools/verify-live-exec.sh` | ✅ **PASS 2026-08-10** | claim 6783, 1/1: `USER.BIN` (a DSK1 flat image built from `user/src/main.zig`) is on the ESP (the image builder embeds it; `ls` lists it), `exec USER.BIN` reads it through the FAT path and replies `exec: loaded USER.BIN size=0x83 entry=0x400000 head=0x200080d2c1020010` (the loaded first instructions), and the program **executes at EL0 from the loaded page** — its sys_write markers (`user: hello from the ESP`, `user: exec ok`), two sequenced pings, `sys_exit` (status 42 → `tasks user-exec exited status=42`), and the idle reap (`tasks user-exec reaped`) are all in `vm-serial.log`, with the shell responsive (`rx-exec-ok`). |
| **Live blocking-syscalls gate** | `bash tools/verify-live-sleep.sh` | ✅ **PASS 2026-08-10** | claim 3200, 1/1: the ESP-loaded program yields (sys_yield, slot 2), sleeps 2 scheduler ticks (sys_sleep, slot 4 — blocked, woken by timer-driven wakeup, return 0), writes the `user: awake` marker after the wake, and exits (status 43); the scheduler's `blocked` state and the worker's advance lines during the sleep window prove live progress of other tasks; `syscalls` reports `4 sys_sleep calls=1` |
| **Live timer IRQ gate** | `bash tools/verify-live-timer.sh` | ✅ **PASS 2026-08-09** | **Real IRQ delivery observed, 3/3 boots (claim 9187):** GICv3 (`GICD` @ `0x10000000`, `GICR`/active frame @ `0x10010000`) + CNTP (24 MHz, GTDT level-triggered PPI 30); each serial log contains `timer irq delivered ppi=0x1e irq_ticks=1` and `timer heartbeat ticks=5 irq=5 poll=0`, with a follow-up shell reply. Claim 7948's platform-blocker conclusion was invalidated by a delivery-blocking guest bug: SGI/PPI MMIO aimed at the RD frame instead of its `+0x10000` SGI frame. The audit also corrected shifted MADT GIC IDs and the wrong ICFGR field bit. Artifacts: `live-timer-*`; Xcode 27 host-surface audit: `vz-irq-api-audit.txt` |
| **Live reboot/shutdown gate** | `bash tools/verify-live-reboot.sh` | ✅ **PASS 2026-08-08** | hard gate 6 closed — a real EFI `ResetSystem` from a live `dipshit>` shell observed end to end (claim 0527, 4/4 boots): `reboot` reset the machine (second full takeover + fresh map key in `vm-serial.log`), `shutdown` powered it off (runner reports VM state → stopped); artifacts `live-reboot-*`. The claim-0011 `M2_RST!` marker write is scanned + reported but is best-effort by design (lost in the teardown race; the machine-level effect is the evidence) |
| **Live virtio-net TX gate** | `bash tools/verify-live-net-tx.sh` | ✅ **PASS 2026-08-11** | claim 1373, 2/2 phases: the virtio-net transport is live on VZ — DID 0x1041, VER1\|MTU\|MAC negotiated (feat=0x28/0x1), host-set MAC from the feature path (02:00:00:00:00:01), queues 0/1 size 4, DRIVER_OK through the re-arm (pre-rearm st=0f — no EBS reset on the net device), and the host capture holds the EXACT frames (phase 1: 46-byte known frame byte-for-byte; phase 2: 46+46+1514 — ring reuse + honest truncation); the 29-gate verify-vz aggregate re-ran green (artifacts `live-net-tx-*`, `live-net-tx-vz-sweep.log`) |
| **Live virtio-net RX gate** | `bash tools/verify-live-net-rx.sh` | ✅ **PASS 2026-08-11** | claim 6076, 3/3 phases: the guest arms queue 0 with a fixed BSS buffer (`net: rx-armed`), the host injects a known frame into the SAME attachment's socket via `--net-inject` (a serial trigger), the polled used-ring drain delivers it, the MAC filter accepts own + broadcast and drops the rest, `net recv` prints the exact bytes, and the guest re-sends them (the phase-1 capture is byte-exactly the injected fixture — the round trip). Claim-time observations: the device writes a 12-byte virtio_net_hdr into RX buffers (num_buffers=1) and refuses an RX buffer under 1530 bytes; the used-buffer IRQ is unobserved (drain polled). The 29-gate verify-vz aggregate re-ran green 29/29 (artifacts `live-net-rx-*`, `m5-net-rx-vz-sweep.log`) |
| **Live virtio-net ARP gate** | `bash tools/verify-live-net-arp.sh` | ✅ **PASS 2026-08-11** | claim 7293, 3/3 phases: the guest's ARP layer (kernel/src/arp.zig) sits on the N2 RX seam — phase 1 the guest answers the injected request for its static IP (the 42-byte reply is byte-exact in the host capture, repl=1, `net recv` observes the request); phase 2 the guest resolves a peer (its broadcast request is byte-exact in the capture and the runner's `--net-arp-respond 10.0.0.2` answer lands: `10.0.0.2 -> 02:00:00:00:00:02`, learn=1); phase 3 a request for a foreign address is dropped (drop=1, repl=0, still observable via `net recv`). Claim-time observation: the device delivers/transmits the 42-byte ARP frames unpadded (below the Ethernet 60-byte minimum). The 31-gate verify-vz aggregate re-ran green 31/31 (artifacts `live-net-arp-*`, `m5-arp-vz-sweep.log`) |
| **Live virtio-net ICMP gate** | `bash tools/verify-live-net-icmp.sh` | ✅ **PASS 2026-08-11** | claim 0148, 3/3 phases: the guest's IPv4 layer (kernel/src/ipv4.zig) sits on the N2 RX seam BESIDE the ARP dispatch — phase 1 the guest answers the injected 46-byte echo request for its static IP (the reply is byte-exact in the host capture with the identification + id/seq/payload echoed, repl=1, `net recv` observes the request at device len 58); phase 2 the guest resolves a peer and pings it (the broadcast ARP request + the 46-byte echo request id/seq 1 are byte-exact in the capture and the runner's `--net-icmp-respond 10.0.0.2` answer lands: pong=1 with seq=1 — the echoed sequence is the ping proof); phase 3 an echo request for a foreign address is dropped (drop=1, repl=0, still observable via `net recv`). No new hardware-contract entry — the 46-byte frames travel unpadded, consistent with the N3 observation. The 32-gate verify-vz aggregate re-ran green 32/32 (artifacts `live-net-icmp-*`, `m5-ipv4-vz-sweep.log`) |
| **Live virtio-net UDP gate** | `bash tools/verify-live-net-udp.sh` | ✅ **PASS 2026-08-11** | claim 8552, 4/4 phases: the guest's UDP layer (kernel/src/udp.zig) sits on the N4 IPv4 seam (protocol-17 dispatch over already-validated frames) — phase 1 LOOPBACK: a send to our OWN IP (10.0.0.1:7000) is delivered directly into the listener's buffer byte-exact (src 7000, dst 7000, len 12, payload 01 02 03 04), rx=1 tx=1 loop=1, and the capture stays EMPTY (no device round trip); phase 2 the host's injected datagram 10.0.0.2:9999 → 10.0.0.1:7000 is delivered byte-exact (net udp recv + the raw frame at device len 58 via net recv), rx=1 drop=0; phase 3 the guest resolves a peer and sends to it (the ARP request + the 46-byte datagram are byte-exact in the capture and the runner's `--net-udp-respond 10.0.0.2:9999` answer — the same payload — lands in the listener buffer, rx=1 tx=1); phase 4 a datagram to a closed port (10.0.0.1:9998) is dropped (drop=1, no delivery, no reply, still observable via `net recv`). Claim-time fix recorded: the pseudo-header zero/protocol word was initially reversed (0x1100 vs 0x0011) — caught by the byte-exact fixtures, fixed, re-run green. No new hardware-contract entry — the 46-byte datagrams travel unpadded, consistent with the N3/N4 observation. The 33-gate verify-vz aggregate re-ran green 33/33 (artifacts `live-net-udp-*`, `m5-udp-vz-sweep.log`) |
| **Live UDP-syscall gate** | `bash tools/verify-live-net-udp-syscall.sh` | ✅ **PASS 2026-08-12** | claim 1384, 4/4 phases: the ADR 0007 slots 9/10/11 driven end to end by UDP.BIN (the first network-syscall user program, loaded by `exec`) — phase 1 the program's transcript IN ORDER: `sys_udp_listen(7000)` → `udp: listen ok`; the LOOPBACK send+recv to its OWN IP → `udp: loop ping` (the 12-byte datagram, byte-exact); the peer send to 10.0.0.2:9999 + poll `sys_udp_recv` of the host's `--net-udp-respond` answer → `udp: got ping` (the cooperative `sys_yield` between polls — the ring returns to the program and the poll succeeds); the `EINVAL` mapping from EL0 (unbound-port recv + unresolved-peer send → `udp: recv err -1` / `udp: send err -1`, nothing transmitted); `sys_exit(17)` → `procs UDP.BIN exited status=17` / `tasks user-exec exited status=17` / `tasks user-exec reaped`; the capture is byte-exact (the 42-byte ARP request + the 46-byte datagram); phase 2 the observation commands on the SAME kernel state: `syscalls` rows 0–11 (implemented=12, rows 9/10/11 counted) + `net udp`/`net` counters rx=2 tx=2 loop=1 drop=0. Gate-engineering lessons recorded: the expect is keyed on the program's OWN completion markers (`udp: got ping` / `tasks user-exec reaped`) — an early expect killed the VM at ~5 s before the ring returned to the program after its yield and a HEALTHY kernel looked hung (switches=5, all tasks ready); the marker greps carry `|| true` so an absent marker FAILS the gate instead of killing it under `set -euo pipefail`. The 34-gate verify-vz aggregate re-ran green 34/34 (artifacts `live-net-udp-syscall-*`, `m5-udp-syscall-vz-sweep.log`) |
| **Live NAT gate** | `bash tools/verify-live-net-nat.sh` | ✅ **PASS 2026-08-12** | claim 4678 (milestone five, card N7): outbound connectivity through `VZNATNetworkDeviceAttachment` live on real VZ — the runner's `--net-nat` attaches the NAT device (mutually exclusive with `--net`, OFF by default — the default VM stays byte-identical); NO guest code, the existing stack is driven against the NAT gateway and the gate asserts GUEST-OBSERVED COUNTERS (the capture-file byte-exact shape does not apply through NAT — the card's documented gate-shape change). ONE run, 11/11 assertions: `net ip 192.168.64.5` (the OBSERVED subnet), the 42-byte ARP request to the gateway, the 46-byte echo request, `pong=1` with `seq=1` (the deterministic gateway round trip — no internet), the learned gateway MAC (`net arp: 192.168.64.1 is at …`), the MAC-under-NAT line (`mac=02:00:00:00:00:01 source=feature` — the NAT attachment honors the configured MAC), `arp=req=1,repl=0,learn=1,drop=1,fail=0`, transport `status=0x0f`, the shell echo, and the runner's `net-nat: ENABLED` line. The 35-gate verify-vz aggregate re-ran green 35/35 (artifacts `live-net-nat-*`, `m5-net-nat-vz-sweep.log`) |
| **Live DHCP gate** | `bash tools/verify-live-net-dhcp.sh` | ✅ **PASS 2026-08-12** | claim 0351 (milestone five, card N8): the bounded RFC 2131 DHCP client on the N5/N6 UDP layer, live on real VZ in TWO phases. Phase 1 (deterministic file-handle): `--net` + `--net-dhcp-respond 10.0.0.2` — the guest's `net dhcp` runs the FULL handshake against the host's crafted server: the 286-byte DISCOVER byte-exact in the capture (dst ff*6, src 02:00:00:00:00:01, 0x0800, 68→67, op 1, cookie, option 53 = 1) → OFFER → the 298-byte REQUEST (the same xid, option 53 = 3) → ACK → `net: dhcp bound ip=10.0.0.2 mask=255.255.255.0 gw=10.0.0.1 server=10.0.0.2 lease=3600`; the report counters `discover=1,offer=1,request=1,ack=1,nack=0,timeout=0,mal=0`; the host's NET-DHCP OFFER + ACK lines. Phase 2 (real NAT, rides `--net-nat`): the CLAIM-TIME observation — the VZ NAT attachment serves NO DHCP server on this host (the DISCOVER went out, `offer=0, mal=0`; honestly recorded in the hardware contract with the saved log under `artifacts/live-net-dhcp-nat-explore/`, never faked), and the guest is NOT stranded: the static fallback still reaches the NAT gateway (`pong=1 seq=1`). The 36-gate verify-vz aggregate re-ran green 36/36 (artifacts `live-net-dhcp-*`, `m5-net-dhcp-vz-sweep.log`) |
| **Live DHCP lease-lifecycle gate** | `bash tools/verify-live-net-dhcp-renew.sh` | ✅ **PASS 2026-08-12** | claim 9489 (milestone five, card N9): the RFC 2131 §4.4.5 lease lifecycle live on real VZ — the client ENFORCES the lease it recorded (T1 = lease/2, T2 = lease*7/8, expiry releases the address). TWO runs: Run A (lease 100 s, `--script2-delay 55` / `--script3-delay 92`) — at elapsed ~57 the client RENEWs with a UNICAST REQUEST to the server (byte-assertable in the 1222-B capture: dst 02:00:00:00:00:02, src/dst IP 10.0.0.2, ciaddr 10.0.0.2) and restarts the lease on the ACK; at elapsed ~93-95 it REBINDs with a BROADCAST REQUEST (frame 4: dst ff:ff:ff:ff:ff:ff); the counters `renew=1,rebind=1,renewed=2,expired=0`. Run B (lease 100 s, delay 106) — `net dhcp: lease expired (elapsed=… >= lease=100)`, the released report (`dhcp=idle,ip=0.0.0.0,…,expired=1` — arp.own_ip cleared), and the client RECOVERS: a fresh DISCOVER → BOUND again. The runner's `--net-dhcp-respond <ip>:<lease>` + `--script2/3-delay` knobs are flag-gated (defaults unchanged — every pre-N9 gate byte-identical). The 37-gate verify-vz aggregate re-ran green 37/37 (artifacts `live-net-dhcp-renew-*`, `m5-net-dhcp-renew-vz-sweep.log`) |
| **Live TCP gate** | `bash tools/verify-live-net-tcp.sh` | ✅ **PASS 2026-08-12** | claim 7026 (milestone five, card N10): the bounded RFC 793 TCP client live on real VZ in THREE runs. Run A (deterministic file-handle): `--net` + `--net-tcp-respond 10.0.0.2:9999` + `--net-arp-respond 10.0.0.2` — the guest's `net tcp` runs the FULL lifecycle: SYN (54 B, byte-exact in the capture — src 8000 → dst 9999, proto 6, flags 0x02) → the host's SYN-ACK (the FIXED server ISN 0x12345678, ack = the guest's ISN+1) → the handshake ACK (ack 0x12345679) → ESTABLISHED → `net tcp send 5` (the data segment 01 02 03 04 05) → the host echoes it (the ACK 0x1234567e) → `net tcp recv` prints `01 02 03 04 05` → `net tcp close` (FIN) → FIN-ACK → the final ACK (0x1234567f) → closed; then a SECOND connect + `net tcp reset` (a real RST). The counters `syn=2,synack=2,ack=4,data_s=1,data_r=1,fin=1,finack=1,rst_s=1,rst_r=0,timedout=0,mal=0`; the 533-byte capture's NINE frames are verified by the gate's python walk (the seq/ack chain, the flags, the ports, the MACs, the payload, and EVERY TCP checksum byte-exact). Run B (deterministic black hole): `--net` + `--net-arp-respond` ONLY — the host answers ARP but never TCP — the bounded connect timeout: `tcp=syn_sent,syn=1,synack=0` → after 31 s `net tcp: connect refused (no SYN-ACK after 30s)` → `tcp=idle,peer=0.0.0.0:0,timedout=1`. Run C (real NAT, rides `--net-nat`): the CLAIM-TIME observation — **the VZ NAT gateway answers the SYN with a RST** (no TCP listener on 192.168.64.1:9999 — connection refused; `rst_r=1`, `tcp=closed`, the drive returns the client to idle; honestly recorded in the hardware contract `[observed]` with the saved logs under `artifacts/live-net-tcp-explore/`, never faked; if a future host's NAT silently drops instead, the honest timeout path fires — proven by Run B). The 38-gate verify-vz aggregate re-ran green 38/38 (artifacts `live-net-tcp-*`, `m5-net-tcp-vz-sweep.log`) |
| **Live TCP retransmission gate** | `bash tools/verify-live-net-tcp-rto.sh` | ✅ **PASS 2026-08-12** | claim 5357 (milestone five, card N11): the bounded retransmission + retransmit timer live on real VZ in THREE runs. Run A (deterministic file-handle, ARP-responder-only — a black-hole SYN): the idle-loop RTO poll retransmits the pending SYN autonomously — `net tcp: syn retransmitted (1/10)` / `(2/10)` — the report reads `retx=2,abort=0` (still `tcp=syn_sent` — the 30 s connect timeout has not expired), and the capture holds the byte-identical SYN frames (the SAME seq/bytes/checksums — a python walk verifies them). Run B (deterministic file-handle + the full responder): the SYN-ACK clears the pending state — `retx=0` in the report despite the 7 s wait (past the RTO), no retransmission lines, and the capture holds EXACTLY ONE SYN (the handshake completes — `established`). Run C (deterministic file-handle + the `:handshake` responder — SYN-ACK yes, data silent, the data black hole): connect → established → `send 5` (never ACKed) → the idle loop retransmits the data TEN times (`data retransmitted (1/10)` … `(10/10)`) → `net tcp: retransmission limit reached (10) — connection aborted` → the report releases the connection (`tcp=idle,peer=0.0.0.0:0,…,retx=10,abort=1`), `net tcp` reads `no connection`, and the capture holds the ELEVEN byte-identical data frames (the initial + the 10 retransmissions). The runner's `--net-tcp-respond …:handshake` mode is flag-gated (default unchanged — every pre-N11 gate byte-identical). The 39-gate verify-vz aggregate re-ran green 39/39 (artifacts `live-net-tcp-rto-*`, `m5-net-tcp-rto-vz-sweep.log`) |
| **Live FAT32 storage gate** (fs hard gate) | `bash tools/verify-live-fs.sh` | ✅ **PASS 2026-08-09** | **hard gate 5 closed, upgraded to a real FAT driver (claim 6420, 1/1 pair)** — `ls`/`cat`/`write` persist through reboot **on the disk itself**: run A wrote `hello world` to the ESP's FAT volume via the virtio-blk transport (write-ok, `hello.txt [esp]` listed, cat reply) and run B — a fresh boot against the **same disk image** — still listed `HELLO.TXT [esp]` (the FAT 8.3 short name) and printed the content. The volume lists the loader's per-boot files too (`EFI/`, `KERNEL.BIN`, `BOOTED.TXT`, `MEMMAP.TXT`, `LOADER.TXT`). Two hardware discoveries landed in the claim: VZ presents virtio-blk as **DID 0x1042** (the spec's modern virtio-blk DID — the transitional scheme maps net 0x1041, blk 0x1042, console 0x1043), and **resets the device at ExitBootServices** — the queue is re-armed post-MMU (`blk_rearm`, common-config MMIO writes verified DRIVER_OK). NVRAM variables are no longer the persistence medium; artifacts `live-fs-*` |
| **Bad-handoff failure gate** | `bash tools/verify-bad-handoff.sh` | ✅ **pass** | `artifacts/m2-badhandoff-fix-after.txt`: `RC.TXT` → `kernel_rc=0x0000000000000002`, gate exits 0 (first observed 2026-08-06, fixed shim) |
| **Marker fallback gate** (gate work item 3) | `bash tools/verify-marker.sh` | ✅ **pass** | `artifacts/m2-marker-gate.txt` (2026-08-07, re-verified `artifacts/m2-marker-reverify-20260807.txt`): NVRAM ladder `M2_ENTRY → … → M2_MAPD! → M2_MMUP! → M2_SERIA → M2_READY` — identity-map switch completes and probe/transport are reached (see [gate work item 3](#immediate-gate-work-prerequisites-for-m15), claims 0009/0010/0013) |
| **MMU-takeover root cause & fix** (claim 0010) | `bash tools/verify-marker.sh` | ✅ **fixed 2026-08-07** | ladder now advances `M2_MAPD! → M2_MMUP! → M2_SERIA` — the identity-map switch **completes** on VZ for the first time (`artifacts/m2-mmu-takeover-gate.txt`; see claim 0010) |
| **VZ serial console discovery** (claim 0013) | pre-exit probe + NVRAM dump | ✅ **discovered 2026-08-07** | console = modern virtio-pci (bus 0 D5 `VID=0x1af4 DID=0x1043 class=0x078000`), ECAM `0x40000000`, BAR0 (64-bit) @ `0x100010000`, transport decoded + armed pre-exit (`SEL=VIRTIO`, ladder `M2_READY`); declared MMIO windows decoded as Apple efivars store + internal debug UART. Gate blocked at the time (post-MMU transport access hung, claims 0018/0020) — **resolved by claim 1517** (T0SZ=16 + TLBI at the switch) |
| **NVRAM console channel** (claim 0015) | `bash tools/verify-nvram-console.sh` | ✅ **PASS 2026-08-07** | **first post-exit console bytes from a real VZ run**: 69–70 chunks reconstructed from `efi-vars.bin` — takeover banner, full memory map, probe record, shell banner, and real `version`/`mem`/`echo`/`help` command output (`artifacts/nvram-console-gate.txt`). Found + fixed a latent kernel bug on the way (ADR 0005: const function-pointer tables are not relocated by the flat loader — the first vtable dispatch on real hardware faulted; tables now built at runtime in BSS). (historical blocker, see git history `aa4f111` and `docs/archive/status-m3-detail.md`) |
| **Custom-virtio host-push round trip** (claim 3141, issue #523 item 3) | `bash tools/verify-cvc-echo.sh` | ✅ **PASS 2026-08-24** | the FIRST HOST-initiated round trip through a host-implemented virtio device: `--cvc-echo` attaches the custom device (VID 0x1af4 / DID 0x1082, class 0x00/0x00) with a THIRD queue; the guest driver pre-arms one device-write receive buffer and signals readiness over the queue-1 log transport (`CUSTOM-VIRTIO-LOG: cvc-push-armed`); the host delegate enqueues `CVC-PING-0x42` (13 B) into it at a moment of its choosing (`nextElement` → write → returnToQueue — the SDK has NO host-side enqueue, so this pre-arm/dequeue/write/return pattern IS the only host→guest data path); the guest reads all 13 bytes byte-exactly (`req=ok handle=ok`), replies verbatim on queue 2, verifies the host's `OK:13` ack (`cvspike: q2 rsp="CVC-PING-0x42" ack="OK:13" ok=1`); the host delegate confirms the reply byte-exactly and writes the ack. Classic queue-0/queue-1 transports + used-ring SPI IRQ (0x45) green in the same boot; shell alive. Regression: `verify-custom-virtio.sh` re-ran PASS unchanged (two-queue world intact — the select=2 size probe reads 0 per spec). API shapes cited from the Xcode 27 Virtualization.framework ObjC headers in claim 3141; PCI identity rationale in hardware-contract.md. Artifacts `live-cvc-*`. Productionization TODO (input injection replacing CGEvent synthesis #179/#151, structured console, framebuffer snapshots) documented there too |
| **Custom-virtio POINTER injection** (claim 9367, issue #523 item 3 / #151) | `bash tools/verify-live-pointer-virtio.sh` | ✅ **PASS 2026-08-24** | pointer injection over the custom-virtio INPUT queue — the productionization TODO above, pointer tranche: kind-2 messages (16-byte envelope, 5-byte payload `[buttons, x_lo, x_hi, y_lo, y_hi]`, HID absolute 0..32767 coords) ride queue 3 into the guest's pre-armed receive pool; the guest hands them to `input.decode_pointer_report` — the exact function an XHCI pointer report takes. The gate is HEADLESS class B: `--screen` only (GPU attached so Driving Award arms; no `--display`, no `--input`, no USB HID device of any kind) + `--via-virtio`; the runner's `--pointer-virtio "200,150;200,150,c;640,600;640,600,c"` waits for a serial trigger then enqueues move/down/up strictly in order at **2.5 s pacing** — presses are edge-detected by `driving_award.pointer_tick`, which runs once per shell-idle pass at the present cadence (~1.5–2 s), and sub-tick spacing collapses clicks (observed live at 0.25 s: all eight reports decoded but zero focus moves). Evidence in one boot: q3 pool armed + claim-3141 push echo green; guest's own report `input: armed=0 … ptr-reports=8` with NO USB device ever attached; two click-driven focus moves printed by the window manager (`dui: pointer focus=2` → `focus=0`); negative proofs — no PTR-EVT/window-key synthesis lines exist on the path. Issue #151's pointer-focus proof is upgraded from class-C-only to class-B-headless (the claim-4769 activation wall cannot apply: there is no window to activate). Wire format normative in hardware-contract.md; regression `GATE_VIRTIO=1 verify-live-input.sh` re-ran PASS unchanged. Artifacts `live-pointer-virtio-*` |
| **Custom-virtio control plane END-TO-END** (claim 0680, issue #523 item 3 capstone) | `bash tools/verify-live-virtio-e2e.sh` | ✅ **PASS 2026-08-24** | the #523 acceptance row proven in ONE headless boot — a gate drives guest input AND reads guest output through the custom-virtio control plane, with NO CGEvent synthesis and NO screenshot scraping anywhere in the critical path. INPUT side: 12 HID-shaped kind-1 messages typed over queue 3 while the terminal owns focus (`input\n` → the guest's report line prints `events=6 … kb-byte=0xa`). STRUCTURED CONSOLE side: the host answers the guest's `cvconsole-ready` with ONE kind-3 message; every console byte is then duplicated onto queue 1 and captured by `--cvc-console-file` — the typed command's own report appears IN THAT FILE (plus the newline-less prompt via the idle-seam partial flush). SNAPSHOT side: a kind-4 request makes the guest stream its composed scanout over the NEW FIFTH QUEUE as tagged header/chunk/done messages (32 KiB chunks × 113, RFC-1071 checksums per chunk + whole frame); the runner reassembles and verifies into a byte-exact 3,686,400-byte raw BGRX file — ScreenCaptureKit is never invoked and its Screen Recording TCC permission is not needed on this path at all. Two live findings fixed en route and pinned in hardware-contract.md: polled sends must free their descriptor chains (the spike's five lines masked a leak that sustained tee traffic exposed within seconds), and RFC-1071 needs a u64 accumulator at whole-frame scale (u32 overflowed as a host-side Swift trap mid-stream). Regressions all PASS unchanged on the same build: `GATE_VIRTIO=1 verify-live-input.sh`, `verify-live-pointer-virtio.sh`, `verify-cvc-echo.sh`, `verify-custom-virtio.sh`. Wire formats normative in hardware-contract.md. Artifacts `live-virtio-e2e-*` |


## The march tracker (per milestone)

> Per-milestone card detail lives in `docs/march-m*.md` (M3, M6–M31);
> completed-milestone trackers are archived — `docs/archive/march-m4.md` (M4),
> `docs/archive/march-m5.md` (M5), and `docs/archive/march-m15.md` (M1.5, closed 2026-08-09).
> `docs/status.md` holds only milestone-level facts; update a card's row in its march file, never here.

## What comes next

Closed milestones M3–M16 are archived (see `docs/archive/status-m*-detail.md` and `docs/march-m*.md`).
The ordered `## What comes immediately afterward` list (previously 223 lines, items 4–18 for M3–M8)
and the `## Milestone 1.5 — the call` spec (56 lines) plus the `## What we directly observe` serial-gate
archaeology (115 lines) are preserved in git history (`aa4f111`) and in the per-milestone archives.

**M17 — desktop completeness** (C1–C10 + Arc1–5): ✅ done 2026-08-21, and the
entire M18–M27 experience layer that followed is closed too — every row above
from Seventeen through Thirty-one is ✅ done with its own GitHub milestone
(GH milestones #6–#15 for M18–M27; issues #595/#598/#599/#602 for M28–M31)
and march tracker (`docs/march-m18.md` … `docs/march-m31.md`; card detail in
[`docs/roadmap-post-arc5.md`](roadmap-post-arc5.md)).

Post-milestone landings since M31: the in-guest HTTP/1.1 web server
`HTTPD.BIN` with TCP passive open (claim 0750, PR #596), the M26 offline-
preflight cards N13/N14 (claim 8852), and the `sys_tcp_connect` wall-clock
bounding fix (issue #613, claim 2572, PR #615).

**There is no M32 yet.** Every GitHub milestone is closed, the issue tracker
is at **zero open issues** (2026-08-28), and no claim is active on a branch —
the repo sits between milestones. The ABI is effectively full: a 128-slot
table with **65 implemented** (ADR 0013 reserved slots 52–54), so the next
milestone is likely predominantly userland unless an ADR amendment grants
more slots. Both former open threads are resolved: the M8 U4 pointer-focus
proof is class-B-headless via custom-virtio pointer injection (claim 9367,
issue #151) and the synthesized-keyboard `events=0` report is fixed by the
headless virtio input channel (claims 9588/0680, issue #179).

**M32 is underway (WMS1 done, planning complete).** The target is the window-manager
*boundary*, not features: today desktop policy is a ~4,740-line kernel
component (`driving_award.zig`) composited from the shell idle loop, with apps
touching it only through draw syscalls. The plan moves policy out into a
userland **WM server** (seam A render-server), leaving the kernel a thin
render + input + surface server, shim-and-slim so nothing regresses. Binding
artifacts: ADR 0015 (slot 65 `sys_wmctl`, event kind 18 `COMPOSITE_TICK`), the
card plan in `docs/march-m32-wm-migration.md` (claim 2852), and **GitHub
milestone 16** (`M32 — Window manager server migration`) carrying the
WMS1–WMS10 cards as issues **#621–#630**. All ten issue bodies are scoped
(2026-08-28, claim 2852): per-card goal, in/out of scope, acceptance gate,
risks and touched files; the work order is pinned in the march tracker's
dependency-phases map (WMS1 contract → WMS2/WMS3 unlock → WMS4–WMS6
drain-out → WMS7 protocol → WMS8/WMS9 payoff → WMS10 deferred).**WMS1 is
done (claim 1484, issue #621): ADR 0015 accepted; slot-65 `sys_wmctl`
subcommand encoding + error contract frozen in ADR 0007; kind-18
`COMPOSITE_TICK` (routing-restricted) in ADR 0009; the `COMPOSITE_TICK`
constant is reserved in `events.zig` (no handler yet — slot 65 still
`-ENOSYS`). WMS2 next (kernel render-server register).**

> https://github.com/drawmeanelephant/DipshitOS/milestone/16

Full detail lives in that ADR and march tracker; this line is pointer-level
only.

## Assumptions & gaps (checked against merged `main`)

- **ADR 0004 console:** polled TX-only virtio-pci (DID 0x1043, BAR 0x100010000, post-MMU TX fixed claim 1517, RX claim 6684).
- **Runner serial input:** evidence path `VZFileHandleSerialPortAttachment(nil)` unchanged; `--console` wires stdin (M1.5).
- **Memory:** `memorySize = 256 MiB`; `mem` derives from captured map.
- **Kernel is post-ExitBootServices, never returns** (handoff v2 in x3, ends in WFE loop).
- **Firmware quirks:** `ConOut` not routed to virtio; kernel drives console itself. See `hardware-contract.md`.

## Multiagent coordination

Multiple agents/humans develop this repo concurrently. Binding rules (mirrored in `AGENTS.md`):

1. **Claim before you start.** Non-trivial work → `docs/claims/<NNNN>-<slug>.md` + `docs/logs/<branch>.md` before code.
2. **One editor per file at a time.** Second waiter merges via integration branch; never concurrent edits to `kernel/src/main.zig`.
3. **Append-only logs, one per branch.** `docs/logs/<branch>.md`; corrections are new entries.
4. **Update on completion/blockers.** Flip claim status and append log; blocked entries prevent repeat attempts.
5. **Own your evidence.** Every `artifacts/` claim cites a saved log.
6. **Doc edits go through this file.** Substance here; other docs are pointers.
7. **Never hand-edit a generated index.** `docs/claims/README.md` / `docs/logs/README.md` are generated by `.github/workflows/indexes.yml` after every merge (claim 2599); branches never commit table churn, and `tools/verify-coordination.sh` checks structure, not drift.

### Active claims

> **How to claim:** copy `docs/claims/TEMPLATE.md` to `docs/claims/<NNNN>-<slug>.md`, set Status `🔄 <branch>` before work,
> and commit — the index tables regenerate after merge via the bot's auto-merge PR (never commit table churn from a branch). Flip to `✅`/`⛔` on completion.
> Canonical index: [`docs/claims/README.md`](claims/README.md).

## Changelog (append-only, per branch)

> Sharded by branch under `docs/logs/` (see [log index](logs/README.md)). This file holds no changelog entries;
> parallel agents never collide here. The final two stragglers were migrated verbatim to `docs/logs/agent-buffy-m15-commands.md` 2026-08-06.

## Immediate gate work (prerequisites for M1.5)

> All three items are **done** (historical). Bad-handoff gate ✅ 2026-08-06 (claim 0001, shim LR fix),
> VZ serial gate ✅ 2026-08-08 (claim 1517, T0SZ=16+TLBI), marker fallback ✅ 2026-08-07 (claim 0009).
> Status lives in claim files; this section is pointer-level only. See [`docs/claims/README.md`](claims/README.md).

## Housekeeping conventions

- **This file is the single source of truth** for status/coordination. Update on gate/milestone changes; claim first; log per branch; refresh indexes.
- **Evidence under `artifacts/`** (gitignored). No evidence ⇒ not observed.
- **Facts vs inference:** hypotheses `(inferred)`; hardware tags flip only with saved logs.
- **Branch hygiene:** `agent/...` branches → PR against `main` (ADR 0003).
- **OS junk:** `.DS_Store` gitignored; `find . -name .DS_Store -delete` when noticed.

## Related docs

- [`roadmap.md`](roadmap.md) — planning + wishlist (destinations, not commitments).
- [`march-m3.md`](march-m3.md) — M3 tracker (active, allocator→sleep).
- [`archive/march-m4.md`](archive/march-m4.md) — M4 tracker (entropy/CSPRNG, GFS, processes; archived).
- [`archive/march-m5.md`](archive/march-m5.md) — M5 tracker (network stack; archived).
- [`march-m6.md`](march-m6.md) — M6 tracker (graphics).
- [`march-m7.md`](march-m7.md) — M7 tracker (input).
- [`march-m8.md`](march-m8.md) — M8 tracker (usability, ADR 0008).
- [`march-m9.md`](march-m9.md) — M9 tracker (app events, ADR 0009).
- [`march-m10.md`](march-m10.md) — M10 tracker (FS ABI, ADR 0010).
- [`march-m11.md`](march-m11.md) — M11 tracker (desktop, ADR 0011).
- [`march-m12.md`](march-m12.md) — M12 tracker (net apps, ADR 0012).
- [`march-m13.md`](march-m13.md) — M13 tracker (files+apps).
- [`march-m14.md`](march-m14.md) — M14 tracker (shared services).
- [`march-m15.md`](march-m15.md) — M15 tracker (audio).
- [`march-m16.md`](march-m16.md) — M16 tracker (kernel consolidation).
- [`m17-desktop-completeness.md`](m17-desktop-completeness.md) — M17 (widgets, menus, resize, tray; done).
- [`roadmap-post-arc5.md`](roadmap-post-arc5.md) — M18–M27 the experience layer (card detail; all closed).
- [`march-m18.md`](march-m18.md) — M18 tracker (terminal & shell depth).
- [`march-m19.md`](march-m19.md) — M19 tracker (shell programming environment).
- [`march-m20.md`](march-m20.md) — M20 tracker (text rendering & Unicode).
- [`march-m21.md`](march-m21.md) — M21 tracker (window management depth).
- [`march-m22.md`](march-m22.md) — M22 tracker (developer tools).
- [`march-m23.md`](march-m23.md) — M23 tracker (the text editor).
- [`march-m24.md`](march-m24.md) — M24 tracker (CALC grows up).
- [`march-m25.md`](march-m25.md) — M25 tracker (file manager depth).
- [`march-m26.md`](march-m26.md) — M26 tracker (network experience).
- [`march-m27.md`](march-m27.md) — M27 tracker (desktop polish & completeness).
- [`march-m28.md`](march-m28.md) — M28 tracker (SMP: symmetric multi-processing; done).
- [`march-m29.md`](march-m29.md) — M29 tracker (VM depth: demand paging, COW, and anonymous mmap; done).
- [`march-m30.md`](march-m30.md) — M30 tracker (dynamic linking & shared libraries; done).
- [`march-m31.md`](march-m31.md) — M31 tracker (dynamic linking ecosystem & userland migration; done).
- [`testing.md`](testing.md) — verification sequence & evidence policy.
- [`hardware-contract.md`](hardware-contract.md) — hardware `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components & data flow.
- [`gate-inventory.md`](gate-inventory.md) — gate classes (A/B/C/D).
- [`archive/`](archive/) — archived one-shots + `status-m*-detail.md` per closed milestone (M3–M16) + frozen designs.
- [`claims/README.md`](claims/README.md) / [`logs/README.md`](logs/README.md) — generated indexes.
- [`../AGENTS.md`](../AGENTS.md) — project rules (incl. multiagent coordination).

