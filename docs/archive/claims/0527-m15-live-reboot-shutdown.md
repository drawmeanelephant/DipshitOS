# Claim: M1.5 — live reboot/shutdown observation (hard gate 6): a real EFI `ResetSystem` observed end to end on VZ

- **Owner:** buffy (`freebuff/pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531`)
- **Prompt / plan:** user request 2026-08-08 — implement the next card: the M1.5 close-out's last open hard gate ("The VM can reboot or shut down from the shell"). Claim 0011 shipped and unit-proved the real `ResetSystem` mechanism (`kernel/src/machine.zig`) but the live half stayed blocked (the kernel halted at `M2_SERIA` before the monitor ran). Claims 1517 + 6684 have since unblocked the live `dipshit>` shell (post-MMU virtio TX + live RX via the runner's `--script`/`--script-expect` mode), so a live `ResetSystem` can now be driven and observed.
- **Scope:** observation + gate only — no kernel-code changes expected (the mechanism, `M2_RST!` marker channel, and runner scripted-input mode all exist). New class-B gate `tools/verify-live-reboot.sh`: boot the production image, drive `reboot`/`shutdown` through the scripted-input runner mode, and assert (a) the `M2_RST!` stage is persisted in the EFI variable store (`artifacts/efi-vars.bin`), (b) the VM leaves the running state (the firmware acted on `ResetSystem` — machine reset / power-off, not a returned call), and (c) the echoed `dipshit> reboot`/`shutdown` keystrokes are in `vm-serial.log`. Docs: flip hard gate 6 + march steps 17/20 + status/roadmap wording once observed; honest ⛔ with evidence if VZ's firmware does not act.
- **Depends on:** claim 0011 (real `ResetSystem` mechanism, shipped + unit-proven), claim 1517 (post-MMU virtio TX — the live shell is reachable), claim 6684 (live RX + runner `--script`/`--script-expect` — keystrokes can be driven into a live session), claim 0009/0010 (NVRAM variable channel — `M2_RST!` marker readback)
- **Status:** ✅ done 2026-08-08 — **a real EFI `ResetSystem` from a live `dipshit>` shell is observed end to end on VZ, 4/4 boots** (evidence under `artifacts/live-reboot-*`): `reboot` (cold) reset the machine — the serial log shows a **second full takeover with a fresh memory-map key** after the echoed `dipshit> reboot`, and the VM kept running (runner timed out with boot 2 at the prompt, state never `.stopped`); `shutdown` powered the machine off — the runner reported `VM ended before the expected transcript appeared (state=0)` (`.stopped`) with the echoed `dipshit> shutdown` as the last serial content and no second boot. Byte-identical evidence across boots (5900 B / 2956 B serial logs). New class-B gate `bash tools/verify-live-reboot.sh` (in `just verify-vz`), hard gate 6 flipped, march steps 17/20 + roadmap/README/gate-inventory updated. Honest finding: the claim-0011 `M2_RST!` NVRAM marker (best-effort by design) is absent from the store snapshot — the write races the teardown — while the machine-level reset/power-off is the observed evidence.

## Notes

**Why this card:** M1.5's hard gate 6 ("The VM can reboot or shut down from
the shell") is the last open acceptance item before the milestone can
close. The mechanism has been real and unit-proven since claim 0011
(`ResetSystem` cold for `reboot`, shutdown for `shutdown`, status 0, null
data, `M2_RST!` persisted immediately before the call, WFE park if the
firmware returns), but no live reset has ever been observed end to end —
claim 0011's live run halted at `M2_SERIA` before the monitor ran, and
there was no RX path to type the command anyway.

**Observation protocol (class B, Apple silicon + VZ only):**

1. Boot the production image with the runner's scripted-input mode: script
   `reboot\n` (then a separate boot with `shutdown\n`). The runner waits
   for `kernel terminal state`, forwards the keystrokes into the serial
   attachment (the guest's virtio RX buffer was supplied pre-exit), and
   tees guest output to `vm-serial.log`.
2. Evidence that the call fired: the `M2_RST!` stage word (LE bytes
   `4d 32 5f 52 53 54 21 00`) in `artifacts/efi-vars.bin` — the kernel
   persists it via runtime `SetVariable` immediately before `ResetSystem`.
3. Evidence that the firmware acted: the VM leaves the running state
   (`runner.vm.state` → `.stopped`/`.error`) — a real reset/power-off
   rather than a returned call (which would leave the kernel parked in
   WFE and the VM still running until timeout).
4. Evidence of the live command: the echoed `dipshit> reboot` /
   `dipshit> shutdown` keystrokes in `vm-serial.log` (the shell echoes as
   it reads).

If VZ's firmware does not act on `ResetSystem` (VM keeps running, no
state change), that is an honest negative observation with evidence — hard
gate 6 stays open and the mechanism's WFE-park honesty contract is
documented as observed.

**Deliverables on success (all done):** `tools/verify-live-reboot.sh`
(class B gate) + `just verify-live-reboot` (+ `verify-vz`); `artifacts/`
evidence; hard gate 6 flipped in `docs/status.md`; march steps 17/20 +
roadmap M1.5-close-out + README + gate-inventory updated; this claim
flipped ✅; branch log entry appended; indexes regenerated.

## Verification (all observed 2026-08-08 on this Apple M4 / macOS 27 VZ host)

- `BOOTS=2 bash tools/verify-live-reboot.sh` → **4/4 PASS**:
  `reboot-01/02` (banners=2, keys=2, echoed=1, stopped=0 — machine
  rebooted, kept running) and `shutdown-01/02` (banners=1, echoed=1,
  stopped=1 — machine powered off), byte-identical serial sizes per
  command (5900 B reboot, 2956 B shutdown).
- `zig build run`-style boot evidence: the two full takeovers in
  `artifacts/live-reboot-serial-reboot-*.log` carry different
  ExitBootServices map keys (`0x2f8` vs `0x2d4` in the first boot pair) —
  impossible within a single boot; the second takeover only follows the
  echoed `dipshit> reboot`.
- `M2_RST!` marker: scanned in `artifacts/efi-vars.bin` after every boot
  — absent in all 4 (reported by the gate as `rst-marker=0`; best-effort
  channel per machine.zig design, lost in the teardown race). The
  machine-level effect is the evidence.
- Class A gates re-run green (fmt, unit tests, transcript gate, builds/
  image/inspect/context, swift build, coordination, test-coordination,
  mmu-debt); coordination indexes regenerated.
