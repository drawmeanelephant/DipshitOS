---
title: Running the VM
parent: getting-started
status: published
tags: [guides, vm]
---

# Running the VM

The VM is launched by a Swift launcher (`host/vm-runner`) built on Apple's
Virtualization.framework. There is no other host.

```bash
zig build run      # boot to the kernel's serial console; output -> artifacts/vm-serial.log
zig build console  # boot an interactive dipshit> console over a live serial attachment
```

The launcher supports flag-gated device modes, all **off by default** so the
default VM stays byte-identical:

| Flag | Attaches |
|------|----------|
| `--console` | an interactive stdin/stdout serial console |
| `--display` / `--screenshot` | the virtio-gpu device (1280×720 scanout) for the graphical terminal and window manager |
| `--input` | the USB keyboard + pointing devices (an Apple XHCI controller) |
| `--net` | the virtio-net device with a deterministic file-handle attachment |
| `--net-nat` | the virtio-net device with a NAT attachment (real outbound connectivity) |

The launcher also carries the deterministic scripted-input and network
responder seams the live gates use (`--script`, `--input-string`,
`--net-udp-respond`, `--net-dhcp-respond`, and so on). Those are test
harness surface, not something an end user typically drives by hand.

## What you should see

A successful `zig build run` ends with the kernel's banner in
`artifacts/vm-serial.log`:

```text
DipshitOS - AArch64 firmware-assisted kernel monitor
Type 'help' before touching anything expensive.
dipshit>
```

From there the interactive monitor serves the [[architecture|kernel]]'s
command surface — `help` lists the registry (44 commands as of the current
tree), from `mem` and `pages` through `exec`, `net`, `screen`, and `win`.

<Aside kind="info">

**CLAIM / EVIDENCE.** The exact serial banner and terminal state are asserted
by the class B gate `zig build run` (claim 1517) and the live transcript gate
(claim 6684). See [[live-gates]].

</Aside>
