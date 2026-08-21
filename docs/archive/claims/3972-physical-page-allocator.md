# Claim: M3 step 1 — physical page allocator over the captured EFI map

- **Owner:** buffy (`freebuff/pull-git-and-check-status-to-make-sure-everything--d4bf6a7f-c051-49b8-a1c4-bc479835e531`)
- **Prompt / plan:** user request 2026-08-08 — implement the next card: a physical page allocator over the captured EFI memory map, with unit tests and the canonical docs/claim ceremony. Canonical ordering: `docs/status.md` ("A physical page allocator over the captured EFI map (deferred)") after the M1.5 close-out (claims 1517/6684/0527).
- **Scope:** new `kernel/src/alloc.zig` — a first-fit **bitmap** physical page allocator whose pool is the **ConventionalMemory** regions of the map the kernel captured pre-exit (ADR 0004 D2: the captured map is the sole authority on layout). Wired into `kernel_main` post-exit (`alloc.init(map_view)`). New `pages` shell command (`pages` = pool stats, `pages selftest` = deterministic bounded alloc/free battery) for live observability. Unit tests (host-side, fixture maps). Docs/claim ceremony. No loader/boot-services-region pooling (explicitly deferred — needs kernel-image/map-buffer exclusion ranges), no buddy/merge, no alignment parameter, no interrupts, no allocation during construction (the bitmap is fixed BSS).
- **Depends on:** M1.5 close-out (claims 1517/6684/0527 — the live shell this command runs in), ADR 0004 (captured-map authority, identity-map 4 GiB blanket), `memmap.zig` (`MapView`/`MemoryDescriptor`), the monitor command registry + mock transcript fixture (both updated here)
- **Status:** ✅ done 2026-08-08 — **physical page allocator implemented, unit-tested (18 tests), wired into the kernel, and observed live on VZ hardware**. `kernel/src/alloc.zig`: first-fit bitmap allocator over the captured map's ConventionalMemory (fixed 128 KiB BSS bitmap over the 4 GiB identity-map span; `alloc_pages`/`free_pages`/`reserve`/`largest_free_run`/`stats`). Wired post-exit in `kernel_main`; new `pages` + `pages selftest` monitor commands; mock-transcript fixture regenerated (2299 → 2922 B); `alloc` added to `tools/verify-unit-tests.sh`. Evidence: `artifacts/live-pages-{run,serial}.log` — live `pages` on real VZ: `armed=1 total=0xee2b free=0xee2b regions=7 span=0xffd7`, and the selftest allocates the largest contiguous run (32768 pages @ 0x70000000), reports exhaustion (`alloc 60972 -> none`), and restores the pool. All class-A gates green (fmt, 62+ unit tests, byte-identical transcript, builds/image/inspect/context, swift, coordination, test-coordination 15/15, mmu-debt); class-B regressions re-run green (serial gate `zig build run`, live-transcript RX 1/1, live-reboot 2/2).

## Notes

**Why this card:** the roadmap's next milestone after M1.5 is a physical
allocator (then GIC/timer, then tasks). This is its first, honest slice:
the kernel can allocate/free physical pages from the map it already owns.
ConventionalMemory-only keeps it safe with zero exclusions — the kernel
image (loader_code), map buffer (loader_data), stack, and virtio BAR are
all outside conventional memory, so the pool can never hand back the
kernel itself.

**Design (all in `kernel/src/alloc.zig` + wiring):**

1. **Bitmap, first-fit.** One bit per 4 KiB page over a 4 GiB physical
   span (the same blanket the identity map covers — `mmu.zig`); 1 =
   allocated, 0 = free. 128 KiB fixed BSS bitmap; regions with a base
   below/above the span are honestly untracked. `State` is an ordinary
   struct (bitmap inline), so host tests build fixture states; module
   state + thin wrappers mirror `machine.zig`'s pattern.
2. **Pool = ConventionalMemory only.** `init(view)` walks the captured
   `MapView`, keeps page-aligned conventional descriptors (whole pages via
   ceil/floor rounding), sets `bitmap_base` = min base, records regions
   (≤ 64), and arms iff ≥ 1 page. No other memory type is pooled — loader/
   boot-services regions are deferred (they need kernel-image + map-buffer
   exclusions).
3. **API:** `alloc_pages(n) -> ?u64` (first-fit contiguous run, null if
   unavailable), `free_pages(base, n) -> bool` (bounds-checked; frees only
   bits that were set, so a double-free frees nothing and reports false),
   `reserve(base, n) -> bool` (atomic check-then-set, for future
   exclusions/pinning), `stats()` (armed/total/free/regions/span). All
   saturating, no allocation, no MMIO.
4. **Observability:** `pages` (stats) + `pages selftest` (deterministic
   battery: alloc 1 / free / alloc 8 / free / alloc 3 + alloc 5 / free
   both / alloc total / free / alloc total+1 → none / verify pool
   restored). The mock transcript e2e test feeds both so the exact output
   is byte-locked in `tests/transcript-console.txt` (regenerated here).

**Verification (all observed 2026-08-08 on this Apple M4 / macOS 27 VZ host):**

- **Class A (repeatable):** `zig test kernel/src/alloc.zig` → 18 tests
  (init/arming, first-fit contiguity, exhaustion, unaligned-base rounding,
  free/reserve bounds, double-free, resettable init, out-of-span
  untracked, > 64 regions cap, gaps never allocatable, largest-free-run);
  `alloc` added to `tools/verify-unit-tests.sh` (62 tests total across
  modules). `zig build test-console` transcript gate byte-identical after
  the fixture regeneration; fmt/build/image/inspect/context/swift/
  coordination/test-coordination (15/15)/mmu-debt all green.
- **Live (class B, real VZ hardware):** `pages` at a live `dipshit>` shell
  reports `armed=1 total=0xee2b (60971) free=0xee2b regions=7 span=0xffd7`
  — the pool is built from the REAL captured map (7 conventional regions,
  ~238 MiB); `pages selftest` allocates the largest contiguous free run
  (32768 pages @ `0x70000000`), proves exhaustion (`alloc 60972 -> none`),
  and restores the pool (`free=0xee2b`). Honest finding surfaced live: the
  pool is fragmented across regions, so "allocate the whole pool" is not
  contiguous — the battery allocates the largest free run instead.
- **Regressions:** `zig build run` (serial gate), `verify-live-transcript.sh`
  (1/1) and `verify-live-reboot.sh` (2/2) all re-run green after the shell
  changes.
