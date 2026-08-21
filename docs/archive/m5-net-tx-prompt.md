# Milestone five, card N1 — virtio-net transport + TX (the network keystone)

> **PLANNING-FIRST — card N1 of milestone five, split from the roadmap's
> network sketch (the last "Eventually" item, `docs/roadmap.md`; the virtio
> surface table's one open row with a driver path). Milestone four is
> closed FIRST — the roadmap's own condition: network "slots after
> milestone four closes (the process/IPC foundations are the dependency)",
> and M4 is still `🚧 active` in `docs/status.md` though every card
> (1/2/3, 3a–3g, 4a/4b/4c) is merged at `9d7e4d5`. N1 then stacks on the
> M4-tagged main. ADR 0007 stays frozen — N1 is a DEVICE DRIVER card, no
> syscall numbering anywhere. No libc/POSIX/heap anywhere. New branch
> `agent/buffy/m5-net-tx`; claim via branch + slug `net-tx` with
> `bash tools/status/claim-id.sh` (the number is TBD at claim time —
> every number in this doc is a suggestion to verify).

## Why

The OS has proven virtio console, block, entropy, and custom devices and a
full process/IPC seam — but it is on NO network: the runner attaches none.
Networking is the roadmap's last open milestone, and N1 is its keystone:
the transport must exist before RX (N2), ARP (N3), or IPv4/ICMP (N4) can.
Every virtio pattern N1 needs is already proven on this exact platform —
discovery + queue setup (claims 0013/6420), used-ring completion
(0828/4374/9492), feature negotiation (9737), and the post-exit re-arm
lesson (6420/2665: VZ resets devices at ExitBootServices) — the device DID
is even predicted (the 2026-08-11 DID correction: modern virtio-net = the
spec's **0x1041**), and the file-handle attachment gives deterministic,
byte-exact gates in the shape of the custom-virtio spike. This is the
lowest-risk rung of the network ladder and the one every later card
presupposes.

## Scope

1. **Runner: a `--net` mode, flag-gated (recommended; the roadmap's
   "one config line" default attach is the alternative — DECIDE at claim
   time and document it).** `host/vm-runner` attaches
   `VZVirtioNetworkDeviceConfiguration` with a
   `VZFileHandleNetworkDeviceAttachment` for the deterministic gates (the
   host writes/reads exact Ethernet frames, like the custom-virtio spike;
   `VZNATNetworkDeviceAttachment` is a LATER card's outbound-connectivity
   option — N1 does not need NAT). Following the `--custom-virtio` /
   `--script` precedents, the attachment must be **off by default** so the
   default VM — and therefore every existing gate in the 28-gate sweep —
   stays byte-identical; the net gate runs with the flag. Set a FIXED MAC
   on the host config (`macAddress`) so the guest's MAC is deterministic
   and gate-assertable.
2. **Guest driver `kernel/src/virtio_net.zig`** (with injectable transport
   ops so the logic is host-testable, the `fat.zig` injected-sector-I/O
   pattern): PCI discovery via the claim-0013 pre-exit path, expecting the
   modern virtio-net DID **0x1041** (every other modern device matched its
   spec DID on VZ — CONFIRM at claim time; record whatever is observed);
   post-exit re-arm of the queues (the claim-6420/2665 lesson, verified
   DRIVER_OK); MAC via `VIRTIO_NET_F_MAC` negotiation (the host-set
   address), falling back to a fixed BSS MAC only if negotiation differs;
   queue 0 (RX) + queue 1 (TX) set up per the virtio-net spec. TX
   completion drained from the used ring — polled (the claim-6420
   one-request-at-a-time blk shape) rather than IRQ for N1; IRQ delivery
   is already proven (claims 9187/0828) and lands with RX in N2.
3. **Bounded frame staging, no heap:** a fixed BSS staging buffer for one
   TX frame (Ethernet header: dst MAC, src MAC, ethertype 0x0800 — raw
   Ethernet for now, payload bounded and truncated honestly). The
   `netsend` command builds the frame in the staging buffer, submits it,
   drains the used ring, and reports byte counts.
4. **Monitor commands:** `net` (registry 32→33: device/DID/MAC/queues/
   feature bits, mirroring the `mbox`/`procs` observability shape) and
   `netsend <bytes>` (sends a known frame — the live gate proves the host
   receives it byte-exact). Honest bounds: N1 drives TX end to end; RX
   buffer supply + used-ring drain + MAC filtering + `net recv` are
   explicitly card N2.
5. **Host tests (class A):** feature-negotiation parsing, MAC read
   (feature path + fallback), frame build (dst/src/ethertype/payload)
   byte-exact against a known fixture, staging-buffer bounds/truncation,
   used-ring drain accounting, `net`/`netsend` output shapes, and the
   command registry rows. `swift build --package-path host/vm-runner`
   covers the `--net` runner change; the transcript fixture must stay
   byte-identical (the default runner config is unchanged).
6. **Hardware contract:** the net device gets NO `[observed]` claim
   without a saved VZ log — the DID (0x1041 expected), the MAC feature,
   and the post-exit re-arm behavior are `[inferred]` until the live gate
   observes them; the contract records the expectation + the
   ExitBootServices-reset prediction up front (the claim-6420/2665
   pattern). If the DID or reset behavior differs, that is a claim-time
   finding, recorded as the 6420/2665 corrections were.
7. **Live gate `tools/verify-live-net-tx.sh` (new, class B):** run with
   the `--net` flag; phase 1 `net | netsend <known-frame> | echo` — the
   host attachment's capture file must contain the EXACT frame bytes the
   guest submitted (byte-exact, the custom-virtio-spike evidence shape),
   and `net` must report the observed DID/MAC/queues. The FULL shared-seam
   live sweep (exec/procs/concurrent/tasks/lifecycle/addrspaces/sleep/svc/
   uaccess/userspace/entropy/long-lived + args/kill/ipc/scale/
   procs-syscall/wait, and the 28-gate aggregate including serial
   takeover) must stay green — proof that the `--net` mode did not disturb
   the default VM. Evidence under `artifacts/live-net-tx-*`.

## Sequence

1. **Close milestone four first** (the roadmap's precondition; mirror the
   claim-0707 M3 close-out): claim-first, full class A + class B gate
   re-run at the merged HEAD, tag, status/roadmap/README/march-m4
   reconciliation. N1 does not start until M4 is tagged.
2. Claim first (this prompt + `docs/claims/<id>-net-tx.md` +
   `docs/logs/agent-buffy-m5-net-tx.md` + `bash tools/status/refresh-indexes.sh`).
3. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console`), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
4. Class B on VZ: the new `verify-live-net-tx.sh` + the FULL shared-seam
   live sweep + the 28-gate aggregate, evidence saved under `artifacts/`.
5. Docs reconciliation: the new `docs/march-m5.md` tracker, roadmap
   (network row flip + the virtio surface table Network row), status
   (milestone-five row + gate table), gate-inventory (new live-net-tx row
   + aggregates), README, hardware-contract (net device `[observed]`
   flips with saved logs only), architecture, claim flip, log append, PR
   per the repo template (real observed evidence only).

## Do not

- Skip or shrink the M4 close-out — network starts only on M4-tagged main.
- Change the default runner config: every existing gate must stay
  byte-identical (the `--net` flag is the only new surface).
- Build ARP/IPv4/ICMP/UDP/TCP in N1 — honest bounds: N1 proves the
  transport + TX; RX (N2) and the protocol ladder (N3/N4, later) are
  separate cards.
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in N1).
- Claim hardware behavior without a saved VZ log (`artifacts/`): the DID,
  MAC feature, and re-arm behavior stay `[inferred]` until observed.
- Hand-edit generated indexes (`refresh-indexes.sh` only).
