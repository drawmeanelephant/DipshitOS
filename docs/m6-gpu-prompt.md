# Milestone six, card G1 — virtio-gpu transport + framebuffer (the graphics keystone)

> **PLANNING-FIRST — card G1 of milestone six, split from the roadmap's
> graphics sketch (`docs/roadmap.md`, "Milestone six — graphics: Driving
> Award + Road Pops"; the virtio surface table's last open row with a
> driver path — the Graphics row). Milestone five is still `🚧 active` in
> `docs/status.md` (N1–N6 merged through 2026-08-12; outbound NAT / DHCP /
> TCP are future rungs) — unlike N1's explicit M4-close precondition, the
> M6 sketch imposes no M5-close gate: G1 stacks on M5-merged main and
> proves itself against the shared seam instead (off-by-default attach +
> the full `verify-vz` aggregate stays green). ADR 0007 stays frozen — G1
> is a DEVICE DRIVER card, no syscall numbering anywhere. No
> libc/POSIX/heap anywhere. New branch `agent/buffy/m6-gpu`; claim via
> branch + slug `gpu` with `bash tools/status/claim-id.sh` (the number is
> TBD at claim time — every number in this doc is a suggestion to
> verify).

## Why

The OS has proven virtio console, block, entropy, custom, and network
devices and a full process/IPC seam — but it renders NOTHING: the runner
attaches the gpu device only for `--screenshot`, the guest has no driver,
and every capture is blank/gray (observed, `docs/hardware-contract.md`).
Graphics is the roadmap's last open milestone, and G1 is its keystone: the
transport and a writable framebuffer must exist before text (G2), Road
Pops (G3), input (G4), or the Driving Award window manager (G5) can. Every
virtio pattern G1 needs is already proven on this exact platform —
discovery + queue setup (claims 0013/6420), used-ring completion
(0828/4374/9492), feature negotiation (9737), and the post-exit re-arm
lesson (6420/2665: VZ resets some devices at ExitBootServices — blk and
entropy reset to `st=00`, the net device does NOT, `st=0f` observed) — the
device DID is even predicted (the modern DIDs are `0x1040 + device_id`:
net 0x1041, blk 0x1042, console 0x1043, entropy 0x1044 observed, so
virtio-gpu = **0x1050**), and the `--screenshot` host path already gives
deterministic pixel evidence in the shape of the net captures. This is the
lowest-risk rung of the graphics ladder and the one every later card
presupposes.

## Scope

1. **Runner: a `--display` mode, flag-gated (recommended; attaching the
   gpu device unconditionally is the alternative — DECIDE at claim time
   and document it).** `host/vm-runner` currently attaches
   `VZVirtioGraphicsDeviceConfiguration` (1280×720 scanout) only under
   `--screenshot`, which also builds the AppKit window
   (`NSApplication`/`NSWindow`/`VZVirtualMachineView`) and captures PNGs
   at 5/10/15 s — today through ScreenCaptureKit's window content filter
   (the runner matches its own window by ID in `SCShareableContent` and
   captures the composited window exactly as the display composites it,
   title bar cropped off via the window's own frame geometry —
   pixel-identical to `--display`), with the older offscreen
   `cacheDisplay` render as the fallback when Screen Recording permission
   (TCC) is not granted. The
   `--display` mode makes the gpu device + the window the whole-session
   surface (the machine boots to a screen the operator can look at) while
   `--screenshot <path>` stays the evidence capture (the two combine:
   `--display --screenshot`). Following
   the `--custom-virtio` / `--script` / `--net` precedents, the attach
   must be **off by default** so the default VM — and therefore every
   existing gate in the 34-gate `verify-vz` sweep — stays byte-identical;
   the gpu gate runs with the flag. Keep the fixed 1280×720 scanout
   (changing it is a claim-time decision with a documented reason).
2. **Guest driver `kernel/src/virtio_gpu.zig`** (with injectable transport
   ops so the logic is host-testable, the `fat.zig` injected-sector-I/O /
   `virtio_net.zig` injected-transport pattern): PCI discovery via the
   claim-0013 pre-exit path, expecting the modern virtio-gpu DID **0x1050**
   (every other modern device matched its spec DID on VZ — CONFIRM at
   claim time; record whatever is observed); feature negotiation per the
   virtio-gpu spec (VERSION_1 at minimum — what else the device accepts
   is observed, not assumed); control queue (queue 0) armed — the cursor
   queue (queue 1) is a later card (G4 input) UNLESS the device demands it
   (claim-time observation); post-exit re-arm of the queues (the
   claim-6420/2665 lesson, verified DRIVER_OK — **does VZ reset the gpu
   device at ExitBootServices? observed, not assumed; the net device did
   NOT, blk/entropy did**).
3. **A writable framebuffer — the exposure mode is a claim-time
   observation.** Plan the spec 2D command path first:
   `GET_DISPLAY_INFO` (read the reported resolution + format) →
   `RESOURCE_CREATE_2D` → `RESOURCE_ATTACH_BACKING` (the framebuffer
   pages) → `SET_SCANOUT` → `TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH`, all
   with a fixed BSS command/response buffer (no heap). The framebuffer
   backing is fixed BSS sized to the negotiated scanout (1280×720×4 ≈
   3.7 MiB at the current config — the exact size/format the device
   reports is observed, and if VZ instead exposes a direct mapping / BAR
   window / `VIRTIO_GPU_F_RESOURCE_MAP`, that is a claim-time finding
   recorded like the 6420/2665 corrections were). G1 does not blit
   content — it proves the path with a solid fill.
4. **Monitor commands:** `screen` (registry 34→35: device/DID/features/
   scanout/format/queues/status/re-arm, mirroring the `net` observability
   shape) and `screen fill <rrggbb>` (solid-fill test — the live gate's
   marker). Honest bounds: G1 drives the transport + a writable
   framebuffer end to end; text rendering, Road Pops, input, and the
   window manager are explicitly cards G2–G5.
5. **Host tests (class A):** feature-negotiation parsing, display-info
   decode, resource-create/attach-backing/set-scanout/transfer/flush
   command builds (byte-exact against known fixtures), framing/response
   validation, the backing-buffer bounds, used-ring drain accounting,
   `screen`/`screen fill` output shapes, and the command registry rows.
   `swift build --package-path host/vm-runner` covers the `--display`
   runner change; the transcript fixture must stay byte-identical (the
   default runner config is unchanged).
6. **Hardware contract:** the gpu device gets NO `[observed]` claim
   without a saved VZ log — the DID (0x1050 expected), the feature set,
   the framebuffer exposure mode (2D command path vs. direct mapping/BAR),
   the pixel format, and the post-exit re-arm behavior are `[inferred]`
   until the live gate observes them; the contract records the
   expectations + the reset prediction up front (the claim-6420/2665
   pattern). If the DID, exposure, or reset behavior differs, that is a
   claim-time finding, recorded as the 6420/2665 corrections were.
7. **Live gate `tools/verify-live-screen.sh` (new, class B):** run with
   `--display` (+ `--screenshot`); phase 1 `screen | screen fill
   <known-rgb>` — the captured PNG must show real guest pixels: decode it
   host-side (pure Python `zlib`+`struct` PNG decode, no PIL — the
   `image/mkfat32.py` pattern; the decode approach is a claim-time
   decision) and assert the fill color in a known region — the **first
   non-blank framebuffer**, the milestone-six G1 marker — and `screen`
   must report the observed DID/features/scanout/format. The FULL
   shared-seam live sweep (the 34-gate `verify-vz` aggregate including
   serial takeover, net, fs, processes) must stay green — proof that the
   `--display` mode did not disturb the default VM. Evidence under
   `artifacts/live-screen-*` (the PNGs + the gate log).

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-gpu.md` +
   `docs/logs/agent-buffy-m6-gpu.md` + `bash tools/status/refresh-indexes.sh`).
   Confirm milestone five is on merged main (N1–N6 are) and no other agent
   owns `host/vm-runner/Sources/VMRunner/main.swift` at claim time (the
   one shared file — the M5 future rungs may touch it too).
2. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console`), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-screen.sh` + the FULL shared-seam
   live sweep + the 34-gate aggregate, evidence saved under `artifacts/`.
4. Docs reconciliation: the `docs/march-m6.md` G1 row flip (✅ only with
   real observed class-B evidence), roadmap (the Graphics row of the
   virtio surface table + the G1 ladder bullet), status (milestone-six row
   + gate table), gate-inventory (new live-screen row + aggregates),
   README, hardware-contract (gpu device `[observed]` flips with saved
   logs only), architecture, claim flip, log append, PR per the repo
   template (real observed evidence only).

## Do not

- Build text rendering (G2), Road Pops (G3), input (G4), or the Driving
  Award window manager (G5) in G1 — honest bounds: G1 proves the transport
  + a writable framebuffer with a solid fill; the ladder is separate
  cards.
- Change the default runner config: every existing gate must stay
  byte-identical (the `--display` flag is the only new surface).
- Add heap, allocation, or unbounded tables; touch the scheduler pool, the
  switching core, the lifecycle states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in G1).
- Claim hardware behavior without a saved VZ log (`artifacts/`): the DID
  (0x1050 expected), the feature set, the framebuffer exposure mode, the
  pixel format, and the reset-at-ExitBootServices answer stay `[inferred]`
  until observed.
- Attach or touch the balloon device, or do any accelerated / 3D work
  (non-goals in the M6 sketch: virtio-gpu 2D blits only, single 1280×720
  scanout, no SMP).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
