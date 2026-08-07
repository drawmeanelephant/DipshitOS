# Log — `agent/buffy/m15-nvram-console`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-07** — **Claim (buffy, `agent/buffy/m15-nvram-console`):** claim
  0015 filed — NVRAM console channel (post-exit console bytes over the
  proven runtime-SetVariable channel, the claim-0013-named successor step
  for the VZ serial gate). Status: 🔄 claimed, implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0015 gate **passes** — post-exit
  console bytes reconstructed from the NVRAM channel on VZ
  (`tools/verify-nvram-console.sh`, evidence under `artifacts/`:
  `nvram-console-gate.txt`, `nvram-console.log`, `nvram-console-run.txt`).
  69–70 chunks covering banner, memory map, probe, seam diag, shell banner,
  and real `version`/`mem`/`echo`/`help` command output — the first
  post-exit console evidence from a real VZ run.

  **Big finding (ADR 0005):** a latent kernel bug — the flat loader copies
  the image to a runtime base without relocations, so `const`
  function-pointer tables in `.rodata` (vtables, the 14-command registry,
  string-slice tables) held link-time absolute addresses. The first vtable
  dispatch on real hardware (the shell seam) faulted instantly; host tests
  never caught it because macOS relocates test binaries. Fixed by building
  all such tables at runtime in BSS (`M15Console.vtable`,
  `monitor.registry`, `machine.control()`, `BootMessages.messages`,
  `elephant_lines`).

  Also fixed: NVRAM store capacity (probe dump gated off in nvram builds;
  the store is ~61 KiB writable, not 128 KiB), chunk cap raised 64→128
  (the cap — not the store — was truncating the session), and the gate now
  retries the documented flaky VZ post-exit death window (claim 0009) up
  to 3 times.

- **2026-08-07** — **Claim (buffy, `agent/buffy/m15-nvram-console`):** claim
  0016 filed — virtio-pci console TX path protocol-correctness review against
  the OASIS Virtio 1.3 spec (before any more VZ-specific debugging). Status:
  🔄 claimed, diagnosis written, fixes landing.

- **2026-08-07** — **Done (buffy):** claim 0016 — three protocol bugs found
  and fixed in the virtio-pci TX path (evidence:
  `artifacts/virtio-spec-review-20260807.txt`):

  1. **Reset readback missing** (§4.1.4.3 MUST): after writing device_status=0
     the driver MUST read it back until 0 before reinitializing; the code
     jumped straight to ACKNOWLEDGE|DRIVER. Now a bounded poll.
  2. **Notify width** (§4.1.5.2.1 MUST): with VIRTIO_F_NOTIFICATION_DATA not
     negotiated the notification MUST be a 16-bit write of the queue index;
     the code issued a 32-bit store. Now `mmio_write16(..., 1)`. The code
     comment justifying the 32-bit store ("16-bit may be dropped — claim
     0013") is an **undocumented inference** — no such evidence exists in
     claim 0013 or its logs; flagged in the report as inference, not
     observation.
  3. **Available-ring overrun hazard** (§2.7 split-ring invariant): queue size
     1, but the flush posted unconditionally even when the previous buffer
     was still outstanding (timeout-drop left it pending). Now the flush
     re-reads used.idx fresh and drops the line without touching the rings
     when the ring is full.
  4. **Used-ring init write vs dc ivac (code-review finding, fixed):** the
     new guard's dc ivac on the used ring can discard the driver's own init
     zeroing of `virtio_used` (BSS not trusted zeroed), so the guard could
     read stale RAM garbage and drop TX forever; the used ring's init write
     is now cleaned to RAM at queue setup.

  Everything else verified correct against the spec (init sequence, feature
  negotiation, common-cfg offsets, queue setup, notify address math, ring
  alignment, cache maintenance). VZ evidence gates re-run: marker ladder
  still reaches M2_READY (transport still arms with the corrected code) and
  the NVRAM console gate still passes. `virtio_init` (virtio-MMIO fallback)
  documented as broken-but-unreachable (never matches on VZ); not in scope to
  fix.
