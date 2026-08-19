# Log — `agent/buffy/m16-c4-composition`

### 2026-08-19 — claim 2714

Claimed. The milestone capstone: one boot proves C1 (GLOBALS.BIN — segmented
image + writable globals), C2 (GUARD.BIN — guard-page fault reaped 139), and
C3 (eight concurrent programs) together. Three scripted phases keep the
transient C1/C2 programs reaped before the C3 fill so the 8-slot budget is
never oversubscribed by a zombie.

## 2026-08-19 — claim 2714 done

One boot proves C1+C2+C3 together (`verify-live-m16-composition.sh` PASS
1/1): GLOBALS.BIN (exit 42) → GUARD.BIN fault reaped 139 beside a
persistent COUNTER.BIN → seven USER.BINs fill the grown pool. Observed
`resources: tasks=11/11 procs=11/16 tables=282/512`.

**Finding:** the first live run failed — the last two USER.BINs were
refused with `table_full` (page-table carve-out exhausted), not `pool_full`.
The carve-out is a TOTAL-roots budget: `mmu.table_count` is a monotonic
cursor, never reclaimed on reap. The composition's roots (28 KiB segmented
app ~44 tables + hostile app + eight concurrent) total 282 pages > the old
256. Grew `mmu.table_page_count` 256 → 512 (2 MiB BSS) and re-derived the
scale gate (`addrspaces: tables=NN/512`) + the monitor `resources` host
test (`tables=0/512`). Also backfilled the missing C1 (`live-m16-image`)
and C2 (`live-m16-guards`) gate-inventory entries while adding the C4 gate.

Re-ran green: scale (tables=238/512), m16-resources, and the composition
gate (final, with the tables-grown assertion). Class-A (fmt, unit tests,
byte-identical transcript, build/image/inspect, coordination) green.
