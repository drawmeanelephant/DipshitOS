# Claim: M1.5 — NVRAM console channel (post-exit console bytes over the proven runtime-SetVariable channel)

- **Owner:** buffy (`agent/buffy/m15-nvram-console`)
- **Prompt / plan:** `docs/status.md` gate work item 2 / march step 8; the
  successor step named by claim 0013: *"carry the console bytes over a
  post-exit-safe channel (the runtime SetVariable NVRAM channel is proven
  alive post-exit)"*
- **Scope:** M1.5 march step 8 remaining work + the live half of step 19 —
  make the kernel's console output host-observable after the MMU switch on
  VZ, without touching the hanging virtio-pci transport
- **Depends on:** claim 0013 (virtio-pci console decoded; post-exit
  transport access hangs on VZ — observed), claim 0009 (NVRAM marker
  channel proven alive post-exit)
- **Status:** ✅ done 2026-08-07 (gate passing — post-exit console bytes
  reconstructed from the NVRAM channel on VZ)

## Notes

**Problem (observed, claim 0013):** the first post-exit banner TX dies in
the virtio-pci transport flush (`vm-serial.log` stays 0 B on every VZ run).
The only proven post-exit device channel is EFI runtime `SetVariable`
(NVRAM): the marker ladder (`DipshitM2`) and the ≤512-byte probe tail
(`DipshitP2`) both persist post-exit. So the console bytes can ride the
same channel.

**Mechanism (kernel, additive):** a new `kernel/src/nvram_console.zig`
module captures the runtime-services `SetVariable` pointer pre-exit and
persists console bytes as chunked EFI variables `DipshitC0, DipshitC1, …`
(each ≤ 256 B payload — under the proven-safe post-exit write budget; each
chunk is a fresh variable, never a big re-write, which is what hangs
post-exit). Chunks are prefixed with the in-band marker `DIPSHITC <idx>:`
so the host can byte-scan the store (same technique as the marker ladder —
no struct-layout parsing). Wired behind a **build option**
`-Dnvram-console=true` (default off, so every existing gate is untouched);
when on, `uart_putc`/`uart_puts` divert to the NVRAM sink and the virtio
transport is never touched post-exit. The shell loop additionally runs a
**scripted session** (`version`, `help`, `mem`, `echo`) served by the
console adapter's `readByte` (a static kernel-side input buffer, not host
keystrokes — live RX stays unclaimed) so real command execution is
observable post-exit.

**Mechanism (host, additive):** the runner gains `--nvram-console <file>`:
before exiting it reconstructs the console bytes from the `DIPSHITC `
chunk markers in `artifacts/efi-vars.bin` (file order == write order,
chunk indices validated sequential from 0), writes the text to `<file>`,
prints it, and the exit code becomes 0 iff reconstructed output is
non-empty. The serial evidence gate is unchanged when the flag is absent.

**Gate (`tools/verify-nvram-console.sh`):** boot the VZ image built with
`-Dnvram-console=true`, assert the reconstructed output contains the
takeover banner (`DipshitOS kernel has seized control.`), the terminal
state line, the `dipshit> ` prompt, and real command output (`dipshit-kernel`,
`mem: descriptors=`). Evidence saved under `artifacts/`.

**Honesty:** the bytes travel the NVRAM channel, NOT the virtio serial
pipe; `vm-serial.log` stays 0 B. The virtio-console TX gate (claim 0002)
remains blocked; this is the fallback channel claim 0013 named, and it
turns the milestone's first post-exit console evidence from impossible to
observable. The scripted input is kernel-side static bytes, not host
keystrokes — host→guest RX remains unclaimed.

## Result (2026-08-07) — gate PASSING

`bash tools/verify-nvram-console.sh` passes (retrying the documented
flaky VZ post-exit death window, claim 0009 — see the script header):

- 69–70 chunks reconstructed (`chunks=70 complete=true bytes=4550`),
  covering the takeover banner, the full 25-descriptor memory map, the
  probe record, the seam diagnostics, the shell banner, and **real
  command output**: `version` → `dipshit-kernel`, `mem` → the full memory
  summary (usable/conventional/runtime/mmio/kernel rows), `echo
  nvram-console-ok` → echoed, and the complete `help` listing (all 14
  commands). This is the first post-exit console evidence from a real VZ
  run in the project's history.
- Evidence: `artifacts/nvram-console-gate.txt`, `artifacts/nvram-console.log`,
  `artifacts/nvram-console-run.txt`, `artifacts/efi-vars.bin`.

**Findings along the way (all observed):**

1. **A latent kernel bug — const function-pointer tables are not
   relocated by the flat loader.** The kernel ELF is linked at address 0
   with no relocations; the loader copies it to a runtime base. `const`
   vtables/registries in `.rodata` therefore held link-time absolute
   addresses, and the first vtable dispatch on real hardware (claim
   0015's shell seam) faulted instantly — chunk 30 (direct `uart_puts`)
   persisted, the first indirect write never did, `writeFn` was never
   entered. Host tests never caught it (macOS relocates test binaries).
   Fix: build every function-pointer table at runtime in BSS (ADR 0005) —
   `M15Console.vtable`, `monitor.registry`, `machine.control()`, and the
   `BootMessages.messages`/`elephant_lines` string-slice tables.
2. **The NVRAM store's writable region is ~61 KiB, not the 128 KiB file.**
   The probe-dump variable (`DipshitProbe`, 20 × 2 KiB) plus the marker
   ladder plus console chunks filled it; both earlier gate runs died at
   exactly 0xf061/0xf069 regardless of content. In nvram-console builds
   the console stream already carries the map/probe evidence, so the
   probe variable is gated off (4 call sites), freeing the store.
3. **The chunk cap, not the store, truncated the session.** With the
   probe gated off, the store still had ~47 KiB free but the old 64-chunk
   cap cut the `help` listing off mid-way; raised to 128 (observed:
   full session ≈ 100 chunks). The scripted session order is now
   `version, mem, echo, help` so the gate-critical needles persist before
   the big help listing.
4. **The VZ post-exit death window is flaky** (claim 0009, observed
   again): runs sometimes die at `M2_MAPD!` (MMU takeover) or mid
   map-dump after `M2_TXOK!`. The gate retries the VM boot up to 3 times
   with a fresh store each attempt and passes on the first complete run.
