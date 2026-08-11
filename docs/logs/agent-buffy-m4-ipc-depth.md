# Log — milestone-four follow-on 4, card 4b: IPC depth — more messages per process ring

- **Branch:** `agent/buffy/m4-ipc-depth` (stacked on the card-4a tree,
  PR #81).
- **Plan:** [`docs/m4-ipc-depth-prompt.md`](../m4-ipc-depth-prompt.md).
- **Claim:** 3179 (deterministic, prompt-first).

## 2026-08-11 — implementation

- Claim 3179 registered (deterministic, prompt-first).
- Option B chosen: `mailbox.max_messages` 4 → 8 (per-process ring 256 →
  512 B, fixed BSS — a data-path constant, no ABI change).
- Re-derived mailbox + syscall ipc host tests at the new capacity; the
  counter's send cadence becomes a 6-per-burst / 5-quiet cycle with an
  `ipc: enospc` failure marker; re-derived `verify-live-ipc.sh`.
- Class A green (fmt, unit tests, transcript, build/image/inspect, swift,
  context, coordination ×2, mmu-debt).
- Class B green on VZ: re-derived live-ipc gate + full shared-seam sweep
  (evidence under `artifacts/live-ipc-*`).
- Docs reconciled (ADR 0007 data-path note, march-m4 row, roadmap,
  status, gate-inventory live-ipc row, README, claim flip); PR #82
  opened.

### Observed evidence (2026-08-11, VZ, `artifacts/live-ipc-*`)

- `verify-live-ipc` boot 01: `sends=12 echoes=11 peak=6 peak_ok=1
  enospc=1 mbox_peer=1 mbox_counter=1 pool_full=1 final_running=1
  never_exited=1` — PASS 1/1.
- The serial log shows the burst: `ipc: ping 1` … `ipc: ping 6`
  back-to-back with no echo between (the peer is not scheduled
  mid-burst); the peer then echoes in order.
- The phase-2 `mbox` snapshot caught the ring mid-drain:
  `mbox: id=1 name=PEER.BIN pending=5 sent=6 recv=1` (sent − recv ==
  pending, ≤ 8) and `mbox: id=2 name=COUNTER.BIN pending=0 sent=0
  recv=0`.
- Zero `ipc: enospc` lines in the whole log.
