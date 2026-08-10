# Milestone 1.5 — the VZ serial/MMU gate run (M1.5 march step 8, claim 0002)

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. This prompt is about **running and honestly recording**
the decisive hardware gate — it implements no new kernel or host features
and must not touch `kernel/` or `host/` code.

- Branch: `agent/.../m15-vz-serial-gate` (suggested; claim first via
  `docs/claims/0002-vz-serial-gate.md` + a log entry in `docs/logs/`)
- Date: 2026-08-06 (refreshed: the bad-handoff fix has landed; the serial
  gate is now the only unpassed milestone-two gate)
- Claim: `docs/claims/0002-vz-serial-gate.md` — currently **⬜ unclaimed**;
  flip it to `🔄 <branch>` before starting, per the coordination rules
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`,
  `docs/march-m15.md` (step 8 and the agent-split table),
  `docs/testing.md`, `docs/hardware-contract.md`,
  `docs/decisions/0004-kernel-proper.md` (D4 serial console, D6 gates),
  `kernel/src/main.zig` (the probe: `probe_serial`, `virtio_init`,
  `uart_putc`), `build.zig` (the `run` step's exact gate)

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host on Apple
M4 / macOS 27, no QEMU path). Read the inputs before doing anything; they
are binding.

## The gate (ADR 0004 D6; `docs/status.md` "Gate status")

The milestone-two primary gate: after a VZ boot, `vm-serial.log` — empty in
every pre-milestone-two run — must contain, in order:

1. The exact banner `DipshitOS kernel has seized control.`
2. A `memory-map descriptors=0x...` line (plus descriptor size/version/key)
3. A `probe base=0x... layout=<kind> records=0x...` line and its
   `probe candidate=...` lines (which MMIO window and which transport won)
4. The `kernel terminal state` marker — the kernel entered its terminal
   WFE loop and did **not** return to the stub

The kernel already implements everything needed to produce this output when
a usable serial transport exists (`kernel/src/main.zig`:
ExitBootServices → identity-map TTBR0_EL1 → `probe_serial` → banner → map
print → probe print → terminal marker). **`zig build run` is itself the
gate**: its `run` step builds + codesigns the Swift runner, boots the VM
with `--expect "DipshitOS kernel has seized control."` and
`--terminal-marker "kernel terminal state"`, then greps `vm-serial.log`
for the banner, `memory-map descriptors=0x`, and the terminal marker,
exiting non-zero if any is missing. A passing `zig build run` **is** the
observed pass; a non-zero exit is a blocked gate, not a "failure" of you.

## Current state (what changed since the previous version of this prompt)

- **The bad-handoff fix landed 2026-08-06** (`agent/buffy/m2-badhandoff-fix`):
  root cause was the naked `_start` shim clobbering `x30`; the two-instruction
  fix makes `RC.TXT` = `kernel_rc=0x0000000000000002` and
  `tools/verify-bad-handoff.sh` exit 0. The shim is **no longer a suspect**
  for the serial gate. This prompt's "run only after the fix lands" condition
  is met; you do not depend on anything unmerged.
- The good-path run still produces **no serial evidence** (`vm-serial.log`
  was 0 bytes; no `RC.TXT` on the good path, which is expected — D6 says
  `RC.TXT` is only a pre-exit failure signal). The open questions remain:
  does VZ expose a usable MMIO serial device at all, and if so which
  transport/base wins the probe.
- M1.5 framing: this gate is march step 8 ("Confirm the serial console")
  in `docs/march-m15.md`; it also unblocks the honest `[inferred] →
  [observed]` flips that M1.5 agent B's RX path will depend on. Agent B's
  console/RX slice is a **separate** stream that proceeds against mocks;
  this gate is yours alone.

## How the probe decides (read `probe_serial` in `kernel/src/main.zig`)

The probe walks only MMIO descriptors **declared by the EFI map** (never an
arbitrary sweep — an absent device must not cause a synchronous abort).
The pre-exit map has observed exactly two MMIO windows,
`0x01000000..0x01010000` and `0x20050000..0x20051000` (range evidence
only — the probe decides what they are). For each window it records
`magic/version/device/layout` and tests, in order:

- **virtio-mmio (modern)**: magic `0x74726976` ("virt"), version 1 or 2,
  device id 3 (console), non-zero vendor, then `virtio_init` (register
  version 2, `VIRTIO_F_VERSION_1`, console transmit queue, DRIVER_OK).
  Selected only if the full init succeeds.
- **PL011**: Peripheral-ID reads at `base+0xfe0/0xfe4/0xfe8` and FR at
  `+0x18`; selected when PID0=0x11, PID1=0x10, PID2=0x14 and the TX-FIFO
  full bit is clear.
- **16550**: byte-wide read-only signature (IER/IIR/LCR/MCR/LSR/MSR/
  scratch); selected on the documented IIR/LCR/MCR/LSR combination with
  scratch != 0xff.

The printed `layout=` names the winner: `PL011`, `16550`, `virtio-console`,
or `none`. **`layout=none` with probe records present is a decisive
observation** ("no usable serial device in the declared windows") — that is
a *result*, not a failure to report; the ADR 0004 D4 fixed-memory-marker
fallback (`M2_TABLE` / `M2_SERIA` / `M2M!` BSS markers) is a **separate
prompt**, not part of this one.

## Scope

Run the gate on the real Apple M4 / macOS 27 host and record the result
honestly. Concretely:

- Run the verification sequence below, saving **every command's output**
  and the **complete** `vm-serial.log` under `artifacts/`.
- Interpret the serial log against the probe design (which windows were
  read, which signatures matched, which transport was selected).
- Update evidence-tagged docs (`docs/status.md` gate table,
  `docs/testing.md` results log, `docs/hardware-contract.md` tags,
  `docs/march-m15.md` step 8) **only** with what the log proves.

**Do not:**

- Modify `kernel/` or `host/` code. No new probes, no forced output, no
  "make the banner appear" hacks.
- Weaken or bypass `zig build run`'s gate (no manual greps that skip the
  real gate, no editing `build.zig`).
- Claim success without the banner in the log. No observed claim without a
  saved log (AGENTS.md evidence rules).
- Run the D4 marker fallback — that is a separate prompt with its own gate.

## Process rule: observe-first (hard gate)

1. **Claim before you start.** Flip `docs/claims/0002-vz-serial-gate.md`
   to `🔄 <branch>`, create your branch log `docs/logs/agent-...-vz-serial-gate.md`
   (first line `# Log — <title>`), and run
   `bash tools/status/refresh-indexes.sh`. A plan entry in the log is
   required *before* running the VM.
2. Read the binding inputs; restate in your plan the exact evidence you
   expect for each possible outcome (pass / partial / no output), quoting
   the exact strings from `kernel/src/main.zig`.
3. Run the build gates, then the VZ run. Save output verbatim.
4. Analyze the logs against the probe design **before** touching any
   evidence-tagged doc.
5. Only then update docs with observed facts, and close your claim + log.

## Verification sequence (run in order; save every output)

```bash
# 1. Tool versions (record which Zig/Swift/macOS you ran on)
zig version; swift --version; sw_vers

# 2. Formatting gate
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig

# 3. M1.5 kernel module unit tests (skips modules not yet landed)
bash tools/verify-unit-tests.sh

# 4–6. Build gates
zig build
zig build inspect
zig build image

# 7. Swift runner build (also exercised inside `zig build run`)
swift build --package-path host/vm-runner --configuration release

# 8. Regression: the bad-handoff failure path must still pass
bash tools/verify-bad-handoff.sh

# 9. THE GATE — boots the VM, writes artifacts/vm-serial.log,
#    gates on banner + map line + terminal marker, exits non-zero if missing
zig build run

# 10. Coordination surface stays green (you touched claim/log files)
bash tools/verify-coordination.sh

# 11. Refresh the deterministic snapshot after doc updates
zig build context
```

Save as `artifacts/m2-vz-run-<YYYYMMDD>.txt` (full `zig build run` output),
`artifacts/m2-vz-gates-<YYYYMMDD>.txt` (steps 2–8), and keep
`artifacts/vm-serial.log` **complete and unmodified** — never truncate,
never summarize, never copy only the matching lines. The runner also
produces `artifacts/vm-screen.png`; keep it.

## Evidence files to save (naming)

| Artifact | From | Purpose |
|----------|------|---------|
| `artifacts/vm-serial.log` | `zig build run` | **The** gate evidence; complete, verbatim |
| `artifacts/m2-vz-run-<date>.txt` | step 9 output | Runner diagnostics, expect/timeout state |
| `artifacts/m2-vz-gates-<date>.txt` | steps 2–8 | Build gates + bad-handoff regression |
| `artifacts/vm-screen.png` | runner | Optional visual (known-blank on VZ) |
| `artifacts/m2-vz-flips-<date>.txt` | you | Log lines that justify each contract flip (quote them) |

## Hardware-contract entries to flip (`docs/hardware-contract.md`, M2 section)

Every flip must quote the matching `vm-serial.log` line in your claim/log.
Everything not listed stays `[inferred]` — including the GIC, MAIR
attribute choices, the entry-time firmware identity map, and the exact IPS
value, none of which this gate observes.

**MMIO / serial console (primary gate evidence):**

1. "A memory-mapped serial console device is reachable by the guest from
   EL1" → `[observed]` **iff** a `probe base=0x... layout=<kind> ...` line
   with `layout != none` appears.
2. "The device's base address and register layout are unknown" →
   `[observed]` with the exact `probe base=`/`layout=` values; note whether
   the base matches one of the two known windows (`0x01000000` or
   `0x20050000`).
3. "Virtio devices sit in an MMIO window whose exact address and transport
   are undocumented" → `[observed]` **only if** `layout=virtio-console`;
   record the base. If PL011/16550 wins, keep it inferred (unchanged).
4. The "two MMIO windows … range evidence only" note may be upgraded to
   "window X confirmed as serial device" **iff** the probe selected it.

**MMU (secondary — flip conservatively):**

5. "The kernel builds its own translation tables (never firmware tables) …
   and runs with them" → the banner is printed *after*
   `install_identity_map()` and a successful probe, so a banner proves
   post-install execution with the kernel's tables. Flip **only** this
   execution fact; the entry-time firmware map, MAIR bit choices, and IPS
   value remain inferred.

## Outcomes — and how to report each honestly

- **Pass:** `zig build run` exits 0; `vm-serial.log` contains banner + map
  line + probe lines + terminal marker. Flip the entries above, update the
  `docs/status.md` gate table row (❌ → ✅ with evidence file + date),
  mark `docs/testing.md` result, flip march step 8 to ✅, close claim 0002
  as ✅ with evidence, append the log, run `refresh-indexes.sh` and
  `verify-coordination.sh`.
- **Blocked — no usable device (`layout=none`):** this is a *clean,
  decisive* result. Record exactly the probe records and the
  `layout=none` line, keep every `[inferred]` tag, flip march step 8 to ⛔
  with the note "no usable MMIO serial in the declared windows", close the
  claim ⛔ or leave it 🔄 with the blocker logged, and name the next step:
  the ADR 0004 D4 fixed-memory-marker fallback prompt.
- **Blocked — no output at all (empty `vm-serial.log`, runner timed out):**
  the kernel died before any post-exit print (early in ExitBootServices /
  map build / MMU install / probe). Record what you *can* observe
  (`BOOTED.TXT`/`LOADER.TXT` on the ESP from the run output, runner exit
  code, `RC.TXT` absence), keep all tags inferred, do **not** modify the
  kernel to "fix" it, flip march step 8 to ⛔ naming the earliest possible
  failure point, append a blocker log entry, and leave claim 0002 🔄/⛔
  per the rules. Name concrete next suspects for a *new* prompt — do not
  improvise fixes here.
- **Blocked — partial output:** quote exactly where it stops (banner but
  no map line? probe records but no `layout=` line?) and say which
  candidate read or print likely faulted. Same honesty rules.

In every blocked case: **no observed without a log, no fabricated output,
no weakened gate.** Save everything, name the precise blocked step, and
leave the repo's hardware claims exactly as evidenced.

## Definition of done

- The gate has been run on Apple M4 / macOS 27 with saved evidence
  (`artifacts/m2-vz-run-<date>.txt`, complete `vm-serial.log`).
- `docs/status.md` and `docs/testing.md` reflect the true outcome; the
  `docs/march-m15.md` step 8 row matches.
- Hardware-contract tags match the evidence exactly — no observed without a
  log line quoted, no inferred where a log exists.
- Claim 0002 closed (✅ with evidence or ⛔ with the blocker) and your
  branch log appended; `refresh-indexes.sh` + `verify-coordination.sh`
  pass.
- No kernel or host feature was added; nothing was fabricated.
