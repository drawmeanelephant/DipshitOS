# Claim: M1.5 — pre-ExitBootServices virtio-pci console TX experiment (diagnostic)

- **Owner:** buffy (`freebuff/pull-the-latest-dipshitos-main-after-the-virtio-pc-fc4c7c03-1dba-4af3-857d-af8cfa2c1e91`)
- **Prompt / plan:** task prompt 2026-08-07 — pull latest main (virtio-pci
  correctness audit, claim 0016, landed), then answer one narrow question
  with direct evidence: **can the current virtio-pci console TX a known
  string while Boot Services and the firmware address space are still
  active?** (pre-ExitBootServices TX diagnostic)
- **Scope:** diagnostic only — a pre-exit TX of a fixed line using the SAME
  discovered device, BAR, capability decoding, negotiated features, TX
  queue, desc/avail/used structures, and notify mechanism the post-exit
  path uses. No RX, no allocator/interrupt work, no console redesign, no
  edit to `docs/status.md`, and the existing milestone success gate is NOT
  replaced (the post-exit TX path is untouched).
- **Depends on:** claim 0013 (transport decode: modern virtio-pci console
  at D5, BAR0 `0x100010000`, common/notify/ISR caps), claim 0016
  (spec-correct TX path — reset readback, 16-bit notify, ring-overrun
  guard), claim 0009 (NVRAM marker channel for bracketing)
- **Status:** ✅ done 2026-08-07 — **A. PRE-EXIT TX WORKS, OBSERVED** (evidence under `artifacts/preexit-tx-gate.txt`, `artifacts/preexit-tx-run.txt`, `artifacts/preexit-marker-dump.txt`, `artifacts/vm-serial.log`, `artifacts/efi-vars.bin`)

## Notes

**Question:** CAN THE CURRENT VIRTIO-PCI CONSOLE TRANSMIT A KNOWN STRING
WHILE BOOT SERVICES AND THE FIRMWARE ADDRESS SPACE ARE STILL ACTIVE?

**Why it matters:** claim 0013 observed that post-exit access to the
transport window hangs on VZ (the first banner TX dies in the first flush).
The remaining ambiguity is *which side* the failure is on: if the very
same transport TX works pre-exit (Boot Services + firmware identity map
still active), then the queue/device/host attachment can communicate and
the failure is somewhere across ExitBootServices/MMU/post-exit access
(interpretation A). If the same TX fails or hangs pre-exit too, the
transport implementation is not yet proven and the project must not blame
the post-exit transition (interpretation B).

**Mechanism (kernel, build-gated `-Dpreexit-tx=true`, default off so every
existing gate is byte-identical):** after the pre-exit probe selects the
virtio-pci console and arms the transport (existing `virtio_pci_init`,
reaches `M2_VPOK!`), a new `preexit_tx_experiment(st)` stages the fixed
line `DIPSHITOS PREEXIT VIRTIO TX\n` into the same `virtio_tx` buffer and
calls the SAME `virtio_pci_flush()` the post-exit path uses (same desc/
avail/used rings, same 16-bit notify, same used-ring poll). The flush is
bracketed by the existing NVRAM marker ladder: new markers `M2_PEXT!`
(experiment entered, about to flush) and `M2_PEXD!` (flush returned), and
the flush's own stage markers `M2_TXST!` (desc/avail posted), `M2_TXNT!`
(notify issued), `M2_TXPL!` (used-ring poll finished) fire pre-exit
because the flush is called with `st_tx` set. If the experiment hangs, the
ladder's last marker names the exact death site. The experiment runs right
after the probe evidence is persisted and immediately before
`write_marker_var(st, marker_prex)` / `ExitBootServices`.

**Mechanism (host):** `tools/verify-preexit-tx.sh` boots the
`-Dpreexit-tx=true` image in a VZ VM, captures `vm-serial.log`, reads the
NVRAM ladder (`--dump-marker`), and reports:

- **A. PRE-EXIT TX WORKS (OBSERVED):** `vm-serial.log` contains the exact
  string `DIPSHITOS PREEXIT VIRTIO TX` — the same device/queue/notify
  communicates while Boot Services + firmware address space are active,
  so the residual failure is across ExitBootServices/MMU/post-exit.
- **B. PRE-EXIT TX DOES NOT WORK (OBSERVED FAILING/HANGING):** the exact
  string never appears and the ladder brackets the failure (e.g. `M2_PEXT!`
  without `M2_TXST!` = hung before descriptor publication; `M2_TXST!`
  without `M2_TXNT!` = hung at descriptor publication/status read;
  `M2_TXNT!` without `M2_TXPL!` = notify issued but used-ring never
  completed; `M2_PEXD!` present but silent = flush returned with no bytes
  reaching the host). The transport is then not yet proven; the post-exit
  transition cannot be blamed.
- **STILL INDETERMINATE:** no ladder bracket and no serial bytes (e.g.
  transport never armed pre-exit).

Loader evidence (`/BOOTED.TXT`, `/LOADER.TXT`) and the EFI variable store
are preserved/copied under `artifacts/` exactly as the existing gates do.

**Honesty:** this is diagnostic evidence only. The post-exit banner TX is
unchanged; `vm-serial.log` continuing to show post-exit bytes still awaits
the (blocked) VZ serial gate. A pre-exit hit does NOT pass claim 0002.

## Result (2026-08-07) — A. PRE-EXIT TX WORKS, OBSERVED

`bash tools/verify-preexit-tx.sh` passes — **observed on three consecutive
VZ boots** (the gate twice + `zig build preexit-tx`), identical every
time, no retries needed:

- **`vm-serial.log` contains exactly `DIPSHITOS PREEXIT VIRTIO TX`** — the
  diagnostic line TX'd through the SAME transport reached the host serial
  attachment while Boot Services and the firmware address space were still
  active (interpretation A).
- **The NVRAM bracket is complete:** `M2_PEXT! → M2_TXST! → M2_TXNT! →
  M2_TXPL! → M2_PEXD!` — descriptor publication, 16-bit notify, and
  used-ring completion all succeeded pre-exit. The ladder then continues
  `M2_PREX! → M2_EXIT! → M2_MAPD! → M2_MMUP! → M2_RAW! → M2_READY`, i.e.
  the experiment did not disturb the takeover, and ends at a second
  `M2_TXST!` — the POST-EXIT banner flush entered (desc/avail posted) but
  never reached `M2_TXNT!` (notify), exactly claim 0013's observed
  post-exit hang. The same code path: pre-exit it works, post-exit it
  hangs.
- **Conclusion:** the virtio queue/device/host attachment CAN communicate;
  the remaining failure is somewhere across ExitBootServices/MMU/post-exit
  access — NOT in the transport implementation as such. The claim-0013
  blocker statement is now refined from "post-exit access hangs" to
  "post-exit access hangs, pre-exit access works": the transition is the
  discriminator.
- **Loader/NVRAM evidence preserved:** `/BOOTED.TXT` (`firmware has agreed
  to cooperate`), `/LOADER.TXT` (base/size/entry/first8 intact),
  `artifacts/efi-vars.bin` (the full store incl. the bracket).
- **No regression:** default-build `zig build`, unit tests (50/50),
  `verify-coordination`, and `verify-marker.sh` all pass; the marker gate's
  ladder still reaches `M2_READY` and hangs at the same post-exit
  `M2_TXST!` as before.

Exact artifact filenames: `artifacts/preexit-tx-gate.txt` (this gate's
complete output), `artifacts/preexit-tx-run.txt` (runner output),
`artifacts/preexit-marker-dump.txt` (ladder bracket),
`artifacts/vm-serial.log` (the diagnostic line), `artifacts/efi-vars.bin`
(store), `artifacts/disk.img` (loader evidence).
