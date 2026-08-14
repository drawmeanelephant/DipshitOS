---
title: Live VZ gates
parent: evidence
status: published
tags: [evidence, class-b, vz]
---

# Live VZ gates (class B)

Class B gates boot a real Virtualization.framework VM on Apple silicon and
assert on what the kernel actually reports. CI cannot run them; a developer
host can (`just verify-vz`).

## Why they exist

The class A floor proves the code paths. The class B gates prove the machine:
that the MMU switch completes under real firmware, that the virtio device
answers, that a typed key reaches the terminal, that a written file survives a
reboot, that a captured Ethernet frame is byte-exact.

## The shape of a gate

Each gate is a `tools/verify-live-*.sh` script that:

1. boots the VM with the right flag-gated device mode;
2. drives a deterministic scripted session (marker-triggered, not sleep-based);
3. asserts on the guest's own serial reports — and, for pixel and network
   gates, decodes the captured PNG or frame bytes;
4. exits 0 only on full evidence.

## A sample of the set

- **Serial / machine** — `live-transcript`, `live-reboot`, `live-timer`, `live-tasks`, `live-exceptions`
- **Userspace** — `live-userspace`, `live-svc`, `live-uaccess`, `live-addrspaces`, `live-lifecycle`, `live-exec`, `live-sleep`
- **Processes** — `live-procs`, `live-concurrent`, `live-long-lived`, `live-kill`, `live-ipc`, `live-scale`, `live-wait`, `live-procs-syscall`
- **Storage / entropy** — `live-fs`, `live-gfs`, `live-entropy`
- **Network** — `live-net-tx`, `-rx`, `-arp`, `-icmp`, `-udp`, `-udp-syscall`, `-nat`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`
- **Graphics / input** — `live-screen`, `live-text`, `live-roadpops`, `live-glyphs`, `live-win`, `live-win-syscall`, `live-win-move`, `live-win-close`, `live-xhci`, `live-usb`, `live-input`

The aggregate `verify-vz` sweep re-checks the shared seam across every
subsystem in one run — the standing regression proof that a new subsystem did
not break the ones before it.

<Aside kind="tip">

**LIVE-GATED.** The strongest single artifact is the byte-exact network
capture: `live-net-udp` and `live-net-tcp` walk the captured frames with a
Python script that verifies every checksum and the sequence/acknowledgment
chain.

</Aside>

<Aside kind="warning">

**LIMITATION.** These gates are hardware-specific and host-specific. A flake is
recorded and re-run rather than hidden — the claim docs name flakes when they
happen.

</Aside>
