# Milestone six, card G2 — framebuffer text rendering (the on-screen words)

> **PLANNING-FIRST — card G2 of milestone six, split from the roadmap's
> graphics sketch (`docs/roadmap.md`, "Milestone six — graphics: Driving
> Award + Road Pops"). Card G1 (claim 6053) is DONE 2026-08-12 — the
> virtio-gpu transport + a writable framebuffer exist, the host has
> already seen the first non-blank pixels (`tools/verify-live-screen.sh`
> PASS 1/1), and the pixel path's claim-time findings are recorded
> (B8G8R8X8 format with an opaque alpha byte, the 2D command path, cache
> cleans before the kick/transfer). G2 stacks on G1-merged main and
> renders TEXT into that framebuffer — the machine starts painting words
> on the screen, the bridge from "pixels" to Road Pops (G3). Milestone
> five is still `🚧 active` in `docs/status.md` — like G1, G2 imposes no
> M5-close gate: it proves itself against the shared seam (off-by-default
> surface + the full `verify-vz` aggregate stays green). ADR 0007 stays
> frozen — G2 is a RENDERING-LAYER card, no syscall numbering anywhere.
> No libc/POSIX/heap anywhere. New branch `agent/buffy/m6-text`; claim
> via branch + slug `text` with `bash tools/status/claim-id.sh` (the
> number is TBD at claim time — every number in this doc is a suggestion
> to verify).

## Why

G1 turned the screen on with a solid fill, but a monitor that shows one
color is still not a terminal — and the milestone's headline is "the
machine boots to a **graphical interface**", with the boot terminal
becoming Road Pops (G3). Today the machine's only visible output is the
serial console (`vm-serial.log` carries the banner + `dipshit>` prompt);
G2 is the layer that makes those same words appear on the framebuffer: a
built-in bitmap font, putc/puts with a cursor, line wrap, bounded
scrollback, and `clear`, all pure logic against G1's B8G8R8X8 framebuffer.
Every prerequisite is already proven on this exact platform: the
framebuffer + transfer/flush path (G1, claim 6053), the injectable-op
host-test pattern (`fat.zig` injected sector I/O / `virtio_net.zig`
injected transport), and the byte-exact transcript discipline (the shell
help + mock-console gates). This is the second-lowest-risk rung of the
graphics ladder and the one G3 (Road Pops) renders through: G3 re-targets
the console's line editor + command registry into a framebuffer region,
which presupposes exactly what G2 builds.

## Scope

1. **Raster module `kernel/src/text.zig`** (pure logic, injectable canvas
   — the fat.zig / virtio_net.zig host-testable pattern): a built-in
   bitmap font as fixed BSS glyph data (the exact font/size is a
   claim-time decision — the shape is: the ASCII printable range
   0x20–0x7e, monospaced, glyphs as bit-packed rows, e.g. 8×16 (2 bytes
   per row ≈ 3 KiB) or 8×8; the data is committed as a Zig array, NO
   runtime file I/O); putc/puts with a cursor (row/col), line wrap at the
   text region's width, a **bounded** scrollback (a fixed BSS text-cell
   ring — the visible window scrolls one line when full, dropping the
   oldest; the depth is a claim-time constant), and `clear`. The renderer
   writes B,G,R,X pixels per the G1-observed scanout format (reusing
   G1's constants — the byte order and the opaque-alpha requirement are
   already in `virtio_gpu.zig`), into a fixed sub-rectangle of `gpu_fb`
   (the text region's position/size is a claim-time constant, named for
   the gate).
2. **Boot-time wiring + monitor command.** After G1's `gpu_setup` fill +
   flush in `kernel/src/main.zig`, the kernel paints its banner + the
   `dipshit>` prompt (the SAME strings the serial log carries — the
   shared-seam proof) into the text region and re-runs transfer + flush,
   so the boot screen shows words over the G1 background fill. A new
   `text` monitor command (registry 35→36) reports the region
   (rows/cols, cell size, cursor row/col, scrollback depth) and drives
   the rasterizer on demand: `text put <string>` / `text clear` — the
   live gate's driver. Honest bounds: G2 renders text into G1's
   framebuffer; the console's line editor / command registry still run
   over serial — re-targeting them to the screen is card G3 (Road Pops).
3. **Host tests (class A).** The raster logic is tested against a mock
   canvas: glyph raster **byte-exact against golden bytes** (per-glyph
   or a known string rendered into a mock B8G8R8X8 buffer), line wrap at
   the region edge, scrollback depth + the dropped-oldest behavior,
   `clear`, cursor movement (putc advances, wrap resets, bounds clamp),
   the B,G,R,X composition (text foreground over the background, the
   opaque alpha byte), the region bounds (a render never writes outside
   the framebuffer), and the `text` command output shapes + the registry
   rows. `swift build --package-path host/vm-runner` is untouched unless
   the gate needs a runner change (it should not — `--display` +
   `--screenshot` already exist from G1). The transcript fixture must
   stay byte-identical (the default boot transcript is unchanged; `text`
   only appears when invoked).
4. **Framebuffer integration.** G2 renders into G1's framebuffer through
   G1's transfer/flush entry points (`gpu_transfer` / `gpu_flush` — the
   full-frame 2D path, already proven). The text foreground/background
   colors are fixed constants (a claim-time decision — e.g. the G1 boot
   background 0x101418 with a light foreground); the gate asserts the
   foreground color family. If the claim finds a reason to change the
   transfer granularity (e.g. a sub-rect transfer for the text region),
   that is a claim-time observation recorded like G1's findings were —
   the default is: reuse G1's full-frame path as-is.
5. **Hardware contract.** G2 adds NO new device — it renders into G1's
   observed device + framebuffer/format. Nothing becomes `[observed]`
   without a saved VZ log; if the claim observes anything new about the
   pixel path (format, transfer semantics, the color-managed shift), it
   is recorded as a G2 finding (the G1 precedent: 0x00ff00 renders
   ~(117,251,76) host-side). No new device rows.
6. **Live gate `tools/verify-live-text.sh` (new, class B).** Run with
   `--display` (+ `--screenshot`); the captured PNG must show TEXT — not
   a solid fill: decode it host-side (the G1 gate's pure-Python
   `zlib`+`struct` PNG decode, no PIL) and assert (a) the text region's
   rows contain foreground-colored pixels over the background (the known
   text color family — the screen is no longer monochrome), and (b) the
   serial transcript still carries the banner + the `text` command's
   reply (the shared-seam proof — the machine still boots to a terminal
   on serial). Honest bound: byte-exact glyphs are asserted in the class
   A mock; the LIVE pixels are color-managed + retina-scaled (G1
   observed the shift), so the live assertion is "text is visible in the
   expected region with the expected color family", not per-glyph
   equality — recorded as the G1 gate's pixel-assertion precedent. The
   FULL shared-seam live sweep (the 35-gate `verify-vz` aggregate) must
   stay green — proof the G2 surface did not disturb the default VM.
   Evidence under `artifacts/live-text-*` (the PNGs + the gate log).
7. **Registry + docs.** The `text` command row (registry 35→36) in the
   shell help + the byte-identical transcript fixture; the march-m6 G2
   row flip (✅ only with real observed class-B evidence); roadmap G2
   bullet; status (milestone-six row + the next-step item); gate
   inventory (live-text row + the 36-gate aggregate); README +
   architecture (`text.zig`); hardware-contract note if a pixel-path
   observation lands. No ADR 0007 touch.

## Sequence

1. Claim first (this prompt + `docs/claims/<id>-text.md` +
   `docs/logs/agent-buffy-m6-text.md` + `bash tools/status/refresh-indexes.sh`).
   Confirm G1 (claim 6053) is on merged main and no other agent owns
   `kernel/src/main.zig` or `kernel/src/monitor.zig` at claim time (the
   shared files — the M5 future rungs and other M6 cards may touch them
   too).
2. Class A first: fmt, unit tests, transcript byte-identical
   (`zig build test-console`), build/image/inspect, swift build, context,
   coordination ×2, mmu-debt.
3. Class B on VZ: the new `verify-live-text.sh` + the FULL shared-seam
   live sweep + the 35-gate aggregate, evidence saved under `artifacts/`.
4. Docs reconciliation: march-m6 G2 flip, roadmap, status,
   gate-inventory, README, architecture, hardware-contract (only with a
   saved log), claim flip, log append, PR per the repo template (real
   observed evidence only).

## Do not

- Build Road Pops (G3 — the console re-target / terminal-on-screen),
  input (G4), or the Driving Award window manager (G5) in G2 — honest
  bounds: G2 renders text into G1's framebuffer; the console's line
  editor + command registry stay on serial until G3.
- Change the default runner config, the boot transcript, or the G1
  framebuffer/format constants: every existing gate must stay
  byte-identical (the `text` command is the only new surface).
- Add heap, allocation, or unbounded tables (the scrollback is a fixed
  BSS ring); touch the scheduler pool, the switching core, the lifecycle
  states, or the process registry.
- Touch syscall numbering at all (ADR 0007 frozen — no syscall in G2).
- Claim pixel-path hardware behavior without a saved VZ log
  (`artifacts/`): the format, the transfer semantics, and the
  color-managed shift stay as G1 observed them unless a G2 finding with
  a saved log overrides.
- Attach or touch any device (G2 adds none), or do any accelerated / 3D
  work (the M6 non-goals: virtio-gpu 2D blits only, single 1280×720
  scanout, no SMP).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
