# DipshitOS verification gate inventory

> Canonical classification of every verification command. **A green GitHub CI
> badge proves class A only** — it says nothing about the Apple-silicon
> Virtualization.framework hardware gates (class B), the interactive gates
> (class C), or the diagnostics (class D). Run the class-B set with
> `just verify-vz` on a real Apple silicon host. Per-gate pass/fail status
> lives in [`docs/status.md`](status.md); this file is the classification,
> not the status.

## Classes

- **A — portable / build CI.** Deterministic, no Apple silicon, no VZ VM.
  Runs in GitHub CI (`.github/workflows/ci.yml`) and as `just verify-portable`
  (`just verify` is a legacy alias). A green CI badge means exactly these
  passed and nothing else.
- **B — Apple-silicon Virtualization.framework hardware gate.** Boots a real
  VZ VM on Apple silicon. GitHub-hosted CI does **not** run these and cannot
  prove them; run `just verify-vz` on a development host. Evidence lives
  under `artifacts/` and status in `docs/status.md`.
- **C — interactive / manual hardware gate.** Requires a human at the
  keyboard. Not automatable, not in CI.
- **D — diagnostic experiment.** Answers a question (claims 0017/0018/0020/
  0021); **not an acceptance gate**. Passing a diagnostic proves nothing
  about the milestone.

## Gate table

| ID | Class | Kind | Gate? | CI? | Apple silicon + VZ? | Command |
|----|-------|------|-------|-----|----------------------|---------|
| `fmt` | A | gate | yes | yes | no | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` |
| `unit-tests` | A | gate | yes | yes | no | `bash tools/verify-unit-tests.sh` |
| `transcript-mock` | A | gate | yes | yes | no | `zig build test-console` (→ `bash tools/verify-transcript.sh`) |
| `guest-build` | A | gate | yes | yes | no | `zig build` |
| `image-build` | A | gate | yes | yes | no | `zig build image` |
| `inspect` | A | gate | yes | yes | no | `zig build inspect` |
| `swift-runner-build` | A | gate | yes | yes | no | `swift build --package-path host/vm-runner` (build only — does not boot) |
| `swift-spike-build` | A | gate | yes | yes | no | `swift build --package-path host/vm-runner -Xswiftc -DSPIKE` on the `xcode-27` public-preview arm64 runner (macOS 27 SDK; compiles the custom-virtio spike, claim 5844; does not boot) |
| `context` | A | gate | yes | yes | no | `zig build context` |
| `coordination` | A | gate | yes | yes | no | `bash tools/verify-coordination.sh` |
| `coordination-tooling` | A | gate | yes | yes | no | `bash tools/status/test-coordination.sh` |
| `mmu-debt` | A | gate | yes | yes | no | `bash tools/verify-mmu-debt.sh` |
| `verify-portable` | A | aggregate | no | no | no | `just verify-portable` (= legacy `just verify`) — the full class-A set |
| `bad-handoff` | B | gate | yes | no | yes | `bash tools/verify-bad-handoff.sh` |
| `marker` | B | gate | yes | no | yes | `bash tools/verify-marker.sh` (mechanism: `zig build marker`) |
| `nvram-console` | B | gate | yes | no | yes | `bash tools/verify-nvram-console.sh` (mechanism: `zig build nvram-console`) |
| `host-console-pty` | B | gate | yes | no | yes | `bash tools/verify-host-console.sh` |
| `serial-takeover` | B | gate | yes | no | yes | `zig build run` — **PASS 2026-08-08** (claim 1517); in `verify-vz` |
| `live-transcript-rx` | B | gate | yes | no | yes | `bash tools/verify-live-transcript.sh` — **PASS 2026-08-08** (claim 6684): live RX, host scripted keystrokes reach the kernel end to end and the `dipshit>` transcript is asserted in `vm-serial.log` |
| `live-exceptions` | B | gate | yes | no | yes | `bash tools/verify-live-exceptions.sh` — **PASS 2026-08-08** (claim 9746): VBAR_EL1 vectors installed; `dipshit> fault` triggers a real synchronous `udf` reported and resumed live (shell continues) |
| `live-timer` | B | gate | yes | no | yes | `bash tools/verify-live-timer.sh` — **PASS 2026-08-09** (claim 9187): a real CNTP PPI enters the EL1 IRQ vector; requires first-IRQ evidence plus `ticks=5 irq=5 poll=0` and a responsive shell; 3/3 boots |
| `live-tasks` | B | gate | yes | no | yes | `bash tools/verify-live-tasks.sh` — **PASS 2026-08-09** (claim 5275): tick-driven round-robin scheduler; the worker's report line (`tasks worker advances=N`, N≥1 — only possible after ≥ 2 real context switches) plus a shell that keeps answering commands proves both tasks advance across ticks |
| `live-userspace` | B | gate | yes | no | yes | `bash tools/verify-live-userspace.sh` — **PASS 2026-08-09** (claim 8215): real EL0t execution, two sequenced `svc #0` entries, return to EL0, timer preemption, and a responsive EL1h shell |
| `live-svc` | B | gate | yes | no | yes | `bash tools/verify-live-svc.sh` — **PASS 2026-08-10** (claim 3594, 1/1): real EL0 write, timer preemption, yield, and non-returning exit through the runtime syscall table; exact one-shot counters and a post-exit shell reply |
| `live-uaccess` | B | gate | yes | no | yes | `bash tools/verify-live-uaccess.sh` — **claim 6120**: EL0 passes an unmapped bad pointer to `sys_write`, observes `-3`/EFAULT, and survives to write a marker; the `uaccess` monitor command runs a validated copy (`valid=1`) and a raw copy from an unmapped address that takes a real EL1 data abort, recovered into EFAULT (`recovered=1`) with the shell still responsive |
| `live-addrspaces` | B | gate | yes | no | yes | `bash tools/verify-live-addrspaces.sh` — **claim 5804**: per-task TTBR0 with an EL1-only kernel overlay (VZ TTBR1 fallback — TTBR1=0, kernel identity-mapped in TTBR0, `t0sz=16`), the EL1h shell/worker tasks on the kernel root, the EL0 task on its OWN root whose EL0-accessible leaves are exactly text+stack (`text=0x00400000 stack=0x80000000`, `el0 >= 3`) with **zero EL0-accessible Device leaves (`el0_device=0`, MMIO excluded from EL0)**; the EL0 payload + uaccess recovery still pass on the new address space |
| `live-lifecycle` | B | gate | yes | no | yes | `bash tools/verify-live-lifecycle.sh` — **claim 6729**: the user task lifecycle — the EL0 task's `sys_exit` turns it into a zombie (`tasks user-el0 exited status=7`), the scheduler-owned **idle task** reaps it (`tasks user-el0 reaped`, pool shrinks), a runtime `spawn` command registers the demo task which enters the ring and advances (`spawn: spawn-demo id=N`, `tasks spawn-demo advances=N`), the `tasks` command reports **explicit states** (`state=` per row + `pool=/5 zombies=` header), and the shell stays responsive throughout |
| `live-exec` | B | gate | yes | no | yes | `bash tools/verify-live-exec.sh` — **claim 6783**: a real user program (`USER.BIN`, a DSK1 flat image) is loaded from the ESP through the claim-6420 FAT path by `exec USER.BIN`, the EL0 user root is rebuilt around its page (claim 5804), and the program executes at EL0 — its `sys_write` markers (`user: hello from the ESP`, `user: exec ok`) and sequenced pings prove the loaded image runs, and `sys_exit` (status 42) + the idle reap (`tasks user-exec exited status=42` / `reaped`) close the claim-6729 lifecycle; the shell stays responsive |
| `live-procs` | B | gate | yes | no | yes | `bash tools/verify-live-procs.sh` — **claim 3848** (milestone-four card 3): the PROCESS abstraction above the task pool — after `exec USER.BIN` the `procs` command shows the exec'd program as a process (`name=USER.BIN state=running stack=0x…`) with the boot payload's process still `exited` (status 7 kept past the executor's reap), and the process-level exit report `procs USER.BIN exited status=43` prints alongside the unchanged task lifecycle (`tasks user-exec exited status=43` + reap) |
| `live-args` | B | gate | yes | no | yes | `bash tools/verify-live-args.sh` — **claim 4636** (milestone-four follow-on 3, card 3e): exec arguments to EL0 — `exec USER.BIN alpha` + `exec USER.BIN beta` back to back: the SAME binary loads twice (`exec: loaded USER.BIN size=` x2), the procs snapshot shows two `name=USER.BIN state=running` rows with distinct task ids + stack VAs, and the DISTINCT markers (`user: arg=alpha` / `user: arg=beta`) prove which invocation is which (the argv block is a bounded 8×32 B read-only leaf in the program's own text page, argc/argv VA passed via the entry contract's x0/x1 — no syscall, ADR 0007 frozen); both programs complete (status 43, EXACT FIFO counts), a third exec is `pool_full` (5/5), and the shell stays responsive |
| `live-concurrent` | B | gate | yes | no | yes | `bash tools/verify-live-concurrent.sh` — **claim 0826** (milestone-four follow-on): TWO live user processes — `exec USER.BIN` runs TWICE back to back (the old one-user-at-a-time `user_busy` gate is gone), the `procs` snapshot shows two `name=USER.BIN state=running` rows with DISTINCT task ids and stack VAs (per-process roots/pages/regions), every EL0 sys_write marker lands twice with the worker's advances between the programs' sleep/wake phases (true interleaving), and both programs reach the exit syscall (`user: awake` x2 — the exit/reap reports are bounded name+status FIFOs (card 3d, claim 1014), so the lines assert EXACT counts: 2 `tasks user-exec exited status=43` / 2 `procs USER.BIN exited status=43` / 2 `tasks user-exec reaped`); the gate captures the full window (no early script-expect) because the 1 s tick makes a USER.BIN lifetime ~10 s |
| `live-long-lived` | B | gate | yes | no | yes | `bash tools/verify-live-long-lived.sh` — **claim 4613** (milestone-four follow-on 2): a LONG-LIVED process among live peers — the second image COUNTER.BIN (distinct `counter: alive` markers, sys_write + sys_yield only, NO sys_exit) runs forever while USER.BIN is exec'd, runs, exits, is reaped (its 5 allocator pages return — the `pages` free count recovers), and is re-exec'd into the freed slot; with the counter + the re-exec'd program both live a further exec reports `pool_full` (the capacity gate, leak-free); the runner's new `--script2`/`--script2-after` second phase forwards the re-exec after the first reap (the primary script is one burst — claim 6684); the counter is `state=running` at the FINAL `procs` and its markers span the whole log (first before the first USER.BIN exit, still landing after the last); the exit/reap reports are bounded FIFOs (card 3d, claim 1014), so the phase-1 exit + the phase-2 re-exec exit assert EXACT counts (2 of each line) with the boot payload's `tasks user-el0 exited status=7` its own distinct line |
| `live-kill` | B | gate | yes | no | yes | `bash tools/verify-live-kill.sh` — **claim 7786** (milestone-four follow-on 3, card 3c): the OS, not the program, owns process lifetime — a NEVER-EXITING COUNTER.BIN is force-terminated by the `kill <pid|name>` monitor command with the reserved status 137; NO `counter: alive` marker lands after the kill line (only one task runs at a time, so the killed task never executes again); the kill flows through the REAL lifecycle (`tasks user-exec exited status=137`, `procs COUNTER.BIN exited status=137`, `tasks user-exec reaped`, procs row `state=exited task=reaped exit=137`); the `pages` free recovers by EXACTLY 5 at the reap; and a phase-3 re-exec lands in the freed slot (same task id the counter had). Three scripted phases (`--script`/`--script2`/`--script3`): phase 1 execs the counter + snapshots, phase 2 kills after the first marker, phase 3 snapshots after the reap |
| `live-ipc` | B | gate | yes | no | yes | `bash tools/verify-live-ipc.sh` — **claims 5965/3179** (milestone-four follow-on 3 card 3f + follow-on 4 card 4b): IPC — distinct processes EXCHANGE DATA on real VZ — `exec PEER.BIN` + `exec COUNTER.BIN 1` back to back (the counter's target pid is argv[0] — card 3e's entry contract): the counter's `ipc: ping N` sends (sys_ipc_send, slot 5) and the peer's byte-exact `peer: got ping N` echoes (sys_ipc_recv, slot 6) INTERLEAVE across the whole log (end-to-end data flow between TWO never-exiting processes through the bounded per-process kernel mailbox — 8×64 B BSS rings, the card-4b capacity); the counter sends BURSTS of 6 messages back-to-back in one quantum (card 4b — `ipc: ping N` … `ipc: ping N+5` with no echo between), so the gate asserts the log's peak (sends − echoes) — the ring depth at its deepest — is >= 5 (> 4 messages queued at once) and <= 8 (never over the re-derived capacity), and ZERO `ipc: enospc` refusal markers; every send except the last in-flight burst window (<= 6) has its byte-exact echo, first echo after the first send; the phase-2 `mbox` snapshot shows PEER.BIN pending <= 8 with sent − recv == pending (the bounded ring DRAINED — observed `pending=5 sent=6 recv=1` mid-drain) and COUNTER.BIN `pending=0 sent=0 recv=0`; both processes are `state=running` at the final `procs` and neither ever exits; a fifth exec is `exec: no free scheduler pool slot` (7/7 pool — card 3g re-derived the refusal); the shell stays responsive. Two scripted phases (`--script` after the boot payload exits, `--script2` after `peer: got ping 1` — the flow is established before the drain snapshot) |
| `live-scale` | B | gate | yes | no | yes | `bash tools/verify-live-scale.sh` — **claim 5795** (milestone-four follow-on 3, card 3g — the pool-scale capstone): FOUR live user programs at the 7-slot budget on VZ — `exec COUNTER.BIN` + `exec USER.BIN` ×3 back to back: the procs snapshot shows FOUR `state=running` user rows (one counter + three USER.BINs) with FOUR distinct executor task ids + stack VAs, the programs' markers + the counter's `counter: alive` markers interleave with the worker's advances across the whole log, a FIFTH exec is `exec: no free scheduler pool slot` (7/7 — shell + worker + 4 users + idle; `pool_full` checked before any allocation, leak-free), `addrspaces: tables=150/256` stays inside the 256-page carve-out (106 pages headroom), the counter is still `state=running` at the final procs, and the shell stays responsive. One scripted phase (`--script` after the boot payload exits) |
| `live-procs-syscall` | B | gate | yes | no | yes | `bash tools/verify-live-procs-syscall.sh` — **claim 5799** (milestone-four follow-on 4, card 4a): the process table read FROM EL0 — `exec PEER.BIN` + `exec COUNTER.BIN 1`: PEER.BIN polls `sys_procs` (slot 7) once per quantum until the snapshot shows a running process other than itself, then prints `peer: sees <pid> <name> <state>` per row — the serial log shows `peer: sees 0 user-el0 exited` / `peer: sees 1 PEER.BIN running` / `peer: sees 2 COUNTER.BIN running` (the counter's RUNNING row visible FROM EL0 — distinct from the EL1h monitor's own `procs` read, which shows both with distinct tasks + stacks); after the snapshot the peer enters its recv loop and the IPC flow still echoes byte-exact (`peer: got ping N`); both processes are `state=running` at the final procs and neither ever exits; the shell stays responsive. Two scripted phases (`--script` after the boot payload exits, `--script2` after the first echo) |
| `live-wait` | B | gate | yes | no | yes | `bash tools/verify-live-wait.sh` — **claim 9946** (milestone-four follow-on 4, card 4c): exit-status propagation to a peer — `exec STATUS43.BIN` + `exec COUNTER.BIN 0 1` (the counter's argv[1] is the wait target): STATUS43.BIN prints its alive marker, sleeps 6 scheduler ticks, then exits 43; the counter prints `ipc: waiting pid=1` and blocks in `sys_wait` (slot 8), and the phase-2 `tasks` snapshot (forwarded after the waiting marker) shows TWO `state=blocked` user-exec rows — the sleeping STATUS43 + the waiting counter — while `procs` still shows `id=1 name=STATUS43.BIN state=running` (the target ALIVE while the waiter is blocked — the blocking proof); then `status43: exiting`, the counter's `ipc: saw pid=1 status=43` (the observation — the ring resumes the counter directly after the target's exit, so it precedes the shell's report drain), and the agreeing kernel records `tasks user-exec exited status=43` / `procs STATUS43.BIN exited status=43` / `tasks user-exec reaped` (the runner's `--script-expect` terminal line); the shell stays responsive. Two scripted phases (`--script` after the boot payload exits, `--script2` after the waiting marker) |
| `live-sleep` | B | gate | yes | no | yes | `bash tools/verify-live-sleep.sh` — **claim 3200**: the ESP-loaded user program yields (sys_yield, slot 2), sleeps 2 scheduler ticks (sys_sleep, slot 4 — blocked, woken by timer-driven wakeup, return 0), writes the `user: awake` marker after the wake, and exits (status 43); the scheduler's `blocked` state and the worker's advance lines during the sleep window prove live progress of other tasks; `syscalls` reports `4 sys_sleep calls=1` |
| `live-entropy` | B | gate | yes | no | yes | `bash tools/verify-live-entropy.sh` — **claim 2665**: the kernel's `random` is served by a REAL virtio entropy device (DID 0x1044) — `entropy: seeded n=64` (the boot-time seed after the post-MMU re-arm), `random 32` emits 64 hex chars, the shell stays responsive, exec still loads with a CSPRNG-randomized stack VA, and TWO boots produce DIFFERENT byte sequences and stack placements (the non-determinism proof) |
| `live-reboot-shutdown` | B | gate | yes | no | yes | `bash tools/verify-live-reboot.sh` — **PASS 2026-08-08** (claim 0527): hard gate 6 — a real EFI `ResetSystem` from a live `dipshit>` shell; `reboot` resets the machine (second full takeover, fresh map key), `shutdown` powers it off (VM state → stopped), 4/4 boots |
| `live-fs` | B | gate | yes | no | yes | `bash tools/verify-live-fs.sh` — **PASS 2026-08-09** (claims 3475/6420): hard gate 5 — `ls`/`cat`/`write` persist through reboot **on the disk** via the FAT32 storage driver (claim 6420: `fat.zig` over the virtio-blk transport, run A writes to the live FAT volume, run B — same disk image — still lists/cats it; NVRAM persistence replaced), 1/1 pair |
| `live-gfs` | B | gate | yes | no | yes | `bash tools/verify-live-gfs.sh` — **claim 3678** (milestone-four card 2): the GENERAL (non-ESP) filesystem on VZ — the disk's second FAT32 partition (Linux-FS type GUID, 36 MiB) is mounted by GUID via `mount data`, its window labeled `[data]` and listed, its files read, `hello.txt` written to it, and run B — same disk image — still lists and prints the file from the DATA volume (persistence on the second volume) |
| `live-net-tx` | B | gate | yes | no | yes | `bash tools/verify-live-net-tx.sh` — **claim 1373** (milestone five, card N1): the virtio-net TRANSPORT + TX on real VZ — runner `--net <capture>` attaches `VZVirtioNetworkDeviceConfiguration` (fixed host MAC 02:00:00:00:00:01); the guest discovers DID 0x1041, negotiates VER1\|MTU\|MAC (the device needs MTU — `feat=0x28/0x1`), reads the host-set MAC via the feature path, arms queues 0/1 size 4, re-arms post-exit (net device does NOT reset at EBS — `net: pre-rearm st=0f`), and `netsend` drives TX with a zeroed 12-byte virtio_net_hdr prefix (observed contract) — the host capture file holds the EXACT Ethernet frames: phase 1 asserts the 46-byte known frame byte-for-byte, phase 2 asserts ring reuse + honest truncation (46 + 46 + 1514 bytes, frames=3); 2/2 phases PASS |
| `verify-vz` | B | aggregate | no | no | yes | `just verify-vz` — serial takeover + bad-handoff + marker + nvram-console + host-console + live-transcript + live-fs + live-gfs + live-exceptions + live-timer + live-tasks + live-userspace + live-svc + live-uaccess + live-addrspaces + live-lifecycle + live-exec + live-procs + live-concurrent + live-args + live-long-lived + live-kill + live-ipc + live-scale + live-procs-syscall + live-wait + live-sleep + live-entropy + live-reboot-shutdown + live-net-tx (Apple silicon only) |
| `console` | C | interactive | yes | no | yes | `zig build console` — interactive host serial console; needs a human at the keyboard |
| `vz-irq-api-audit` | D | diagnostic | no | no | yes | `bash tools/audit-vz-irq-api.sh` — read-only selected-Xcode SDK audit of Virtualization.framework and Hypervisor.framework GIC surfaces; claim 9187; no VM boot |
| `preexit-tx` | D | diagnostic | no | no | yes | `bash tools/verify-preexit-tx.sh` (mechanism: `zig build preexit-tx`) — claim 0017 |
| `tx-diag` | D | diagnostic | no | no | yes | `bash tools/verify-tx-diag.sh` (mechanism: `zig build tx-diag`) — claim 0018 |
| `tx-transition` | D | diagnostic | no | no | yes | `bash tools/verify-tx-transition.sh` — claim 0020 |
| `fw-mmu-capture` | D | diagnostic | no | no | yes | `bash tools/verify-fw-mmu-capture.sh` — claim 0021 |
| `t0sz25` | D | diagnostic | no | no | yes | `bash tools/verify-t0sz16.sh` (mechanism: `zig build kernel -Dt0sz25`) — claims 6460/1517 (legacy start-level regression) |
| `walk-probe` | D | diagnostic | no | no | yes | `zig build kernel -Dwalk-probe` (cold-address probe battery, `M2_WP_*` markers) — claims 7896/1517 |
| `t0sz16-walkprobe` | D | diagnostic | no | no | yes | `bash tools/verify-t0sz16-walkprobe.sh` — claims 7896/1517 (start-level/residual separation + production regression matrix) |

Notes:

- **Raw build steps are classed with their gate.** `zig build marker`,
  `zig build nvram-console`, `zig build preexit-tx`, `zig build tx-diag`,
  `zig build bad-handoff` are the mechanisms behind their verify scripts and
  boot VZ VMs, so they carry the same class (B or D) and the same Apple
  silicon requirement. `zig build kernel` and `zig build bad-handoff` build
  artifacts only (no VM) and are class-A tooling, not gates.
- **Tooling that is not a verification gate:** `ragshit`, `just impact`,
  `just refresh-indexes` are developer tooling, not gates.
- **Class A is exactly what GitHub CI proves.** CI also builds the Swift
  runner, but a successful build is not a boot; only class-B runs on Apple
  silicon produce hardware-gate evidence.
- **`swift-spike-build` runs on the `xcode-27` public-preview runner.**
  GitHub announced the Xcode 27 image (arm64, macOS 26 OS with Xcode 27 /
  the macOS 27.0 SDK) on 2026-07-16. It is the only GitHub-hosted way to
  compile the macOS-27-only custom-virtio spike (claim 5844); the
  macos-latest job builds the base runner against the macOS 26 SDK. The
  spike check boots no VM, so it stays class A despite needing the newest
  SDK.

## Machine-readable records

Fixed-width prefix, `cmd=` is the last field and may contain spaces. A
preflight can extract records with
`sed -n '/^<!-- GATE_INVENTORY:START -->$/,/^<!-- GATE_INVENTORY:END -->$/p'`
and filter on `class=…`, `ci=…`, `apple=…`, `gate=…`.

<!-- GATE_INVENTORY:START -->
GATE id=fmt class=A kind=gate ci=yes apple=no gate=yes cmd=zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
GATE id=unit-tests class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-unit-tests.sh
GATE id=transcript-mock class=A kind=gate ci=yes apple=no gate=yes cmd=zig build test-console
GATE id=guest-build class=A kind=gate ci=yes apple=no gate=yes cmd=zig build
GATE id=image-build class=A kind=gate ci=yes apple=no gate=yes cmd=zig build image
GATE id=inspect class=A kind=gate ci=yes apple=no gate=yes cmd=zig build inspect
GATE id=swift-runner-build class=A kind=gate ci=yes apple=no gate=yes cmd=swift build --package-path host/vm-runner
GATE id=swift-spike-build class=A kind=gate ci=yes apple=no gate=yes cmd=swift build --package-path host/vm-runner -Xswiftc -DSPIKE  # xcode-27 public-preview runner (macOS 27 SDK); claim 5844
GATE id=context class=A kind=gate ci=yes apple=no gate=yes cmd=zig build context
GATE id=coordination class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-coordination.sh
GATE id=coordination-tooling class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/status/test-coordination.sh
GATE id=mmu-debt class=A kind=gate ci=yes apple=no gate=yes cmd=bash tools/verify-mmu-debt.sh
GATE id=verify-portable class=A kind=aggregate ci=no apple=no gate=no cmd=just verify-portable
GATE id=bad-handoff class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-bad-handoff.sh
GATE id=marker class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-marker.sh
GATE id=nvram-console class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-nvram-console.sh
GATE id=host-console-pty class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-host-console.sh
GATE id=serial-takeover class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=zig build run
GATE id=live-transcript-rx class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-transcript.sh
GATE id=live-exceptions class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-exceptions.sh
GATE id=live-timer class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-timer.sh
GATE id=live-tasks class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-tasks.sh
GATE id=live-userspace class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-userspace.sh
GATE id=live-svc class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-svc.sh
GATE id=live-uaccess class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-uaccess.sh  # claim 6120: EFAULT contract + fault recovery
GATE id=live-addrspaces class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-addrspaces.sh  # claim 5804: per-task TTBR0 + EL1-only kernel overlay, MMIO excluded from EL0 (VZ TTBR1 fallback)
GATE id=live-lifecycle class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-lifecycle.sh  # claim 6729: user task lifecycle — spawn / exit / reap + explicit states + idle task
GATE id=live-exec class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-exec.sh  # claim 6783: load + exec a user program from the ESP at EL0
GATE id=live-procs class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-procs.sh  # claim 3848: process abstraction — procs table + process exit report above the task pool
GATE id=live-args class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-args.sh  # claim 4636 (card 3e): exec args to EL0 — same binary, distinct argv (user: arg=alpha / arg=beta), read-only 8×32 B block in the program's own text page, argc/argv via entry-contract x0/x1, both programs live + pool_full third exec, EXACT report counts
GATE id=live-concurrent class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-concurrent.sh  # claim 0826 + card 3d (claim 1014): two live user processes — exec twice without exit, distinct roots/stacks/tasks, markers interleaving, EXACT exit/reap report counts (FIFO)
GATE id=live-long-lived class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-long-lived.sh  # claim 4613 + card 3d (claim 1014): a long-lived process among live peers — never-exiting COUNTER.BIN, USER.BIN exit/reap/re-exec, pages returned, pool_full with both live (two-phase script via --script2), EXACT report counts
GATE id=live-kill class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-kill.sh  # claim 7786: the kernel owns process lifetime — kill a never-exiting COUNTER.BIN (reserved status 137, no markers after the kill line, exact +5 page recovery, re-exec into the freed slot; three-phase script via --script3)
GATE id=live-ipc class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-ipc.sh  # claim 5965 (card 3f): IPC — two never-exiting processes exchange data through the bounded per-process mailbox (slots 5/6) — ipc: ping N sends interleave with byte-exact peer: got ping N echoes, mbox drained (pending<=1, sent-recv==pending), both still running, fifth exec pool_full at 7/7 (two-phase script via --script2)
GATE id=live-scale class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-scale.sh  # claim 5795 (card 3g): pool-scale capstone — FOUR live user programs at the 7-slot budget (counter + 3 USER.BINs, distinct tasks + stacks), markers interleave with the worker, fifth exec pool_full, addrspaces tables=150/256 inside the carve-out
GATE id=live-procs-syscall class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-procs-syscall.sh  # claim 5799 (card 4a): process observability — PEER.BIN reads the process table FROM EL0 via sys_procs (slot 7) — peer: sees 2 COUNTER.BIN running (the counter visible from EL0), the exited boot row too, ipc flow still echoes, both never-exiting (two-phase script via --script2)
GATE id=live-wait class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-wait.sh  # claim 9946 (card 4c): exit-status propagation — STATUS43.BIN sleeps 6 ticks then exits 43; COUNTER.BIN blocks in sys_wait (slot 8) and observes ipc: saw pid=1 status=43, with a phase-2 snapshot of TWO blocked user-exec tasks while the target's procs row still reads running (two-phase script via --script2)
GATE id=live-entropy class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-entropy.sh  # claim 2665: virtio entropy -> CSPRNG seed -> random command (2 boots, non-deterministic)
GATE id=live-reboot-shutdown class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-reboot.sh
GATE id=live-fs class=B kind=gate ci=no apple=yes gate=yes status=pass cmd=bash tools/verify-live-fs.sh  # claim 6420: FAT32 storage driver (persistence on the disk, not NVRAM)
GATE id=live-gfs class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-gfs.sh  # claim 3678: general (non-ESP) filesystem — data partition mounted by GUID, persistent across boots
GATE id=live-net-tx class=B kind=gate ci=no apple=yes gate=yes cmd=bash tools/verify-live-net-tx.sh  # claim 1373 (milestone five, card N1): virtio-net transport + TX — runner --net attaches the net device (fixed host MAC); the guest discovers DID 0x1041, negotiates VER1|MTU|MAC (device needs MTU), reads the MAC via the feature path, arms queues 0/1, re-arms post-exit (no EBS reset — pre-rearm st=0f), prepends the 12-byte virtio_net_hdr (observed), and netsend's frames land in the host capture byte-exactly (46-byte fixture, ring reuse, 1500-byte truncation)
GATE id=verify-vz class=B kind=aggregate ci=no apple=yes gate=no cmd=just verify-vz  # serial takeover + bad-handoff + marker + nvram-console + host-console + live-transcript + live-fs + live-gfs + live-exceptions + live-timer + live-tasks + live-userspace + live-svc + live-uaccess + live-addrspaces + live-lifecycle + live-exec + live-procs + live-concurrent + live-args + live-long-lived + live-kill + live-ipc + live-scale + live-procs-syscall + live-wait + live-sleep + live-entropy + live-reboot-shutdown + live-net-tx
GATE id=console class=C kind=interactive ci=no apple=yes gate=yes cmd=zig build console
GATE id=vz-irq-api-audit class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/audit-vz-irq-api.sh
GATE id=preexit-tx class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-preexit-tx.sh
GATE id=tx-diag class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-diag.sh
GATE id=tx-transition class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-tx-transition.sh
GATE id=fw-mmu-capture class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-fw-mmu-capture.sh
GATE id=t0sz25 class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-t0sz16.sh
GATE id=walk-probe class=D kind=diagnostic ci=no apple=yes gate=no cmd=zig build kernel -Dwalk-probe
GATE id=t0sz16-walkprobe class=D kind=diagnostic ci=no apple=yes gate=no cmd=bash tools/verify-t0sz16-walkprobe.sh
<!-- GATE_INVENTORY:END -->
