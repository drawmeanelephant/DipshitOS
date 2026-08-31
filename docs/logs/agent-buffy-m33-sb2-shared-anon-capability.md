# Log — agent/buffy/m33-sb2-shared-anon-capability

## 2026-08-30 — claim 8878 opened (SB2: shared-anon mmap capability)

Capability card on `agent/buffy/m33-sb2-shared-anon-capability` off `main`
(PR #686 merged). Implements the cross-process shared-anonymous mmap behind the
frozen `M33_MAP_SHARED` flag (bit 16) on `sys_mmap` (slot 63), using ONLY the
existing M29 machinery (`alloc.ref_page`/`unref_page` + `mmu.map_user_cow_page`/
`sw_cow`) at the region level and the reviewed D2 rule from `shared_region.zig`.
No new syscall slot.

## 2026-08-30 — claim 8878 done (capability wired, page-proof host tests green)

Delivered + verified green (`zig build`, full host suite incl. the new
shared_region page-proof tests, fmt, coordination, BSS budget): owner create
path in `handle_mmap` (alloc-pages once, `shared_region.create`, record pa/va,
map owner-writable leaves); WM grant path (`authorize_read` -> `grant_read` ->
`ref_page` + map EL0-RO `sw_cow` leaves into the WM root); revoke on owner
`munmap`/exit (`drop_owner` -> unmap WM RO leaves + unref + free). Host proof:
two roots (owner + WM) map the same physical PA, owner writable + peer RO;
owner teardown revokes the peer. SB2 tracker row flipped. Claim 8878.
## 2026-08-31 — claim 8878 live gate PASS (two EL0 roots, one region; revoke proven)

The class-B proof is green on real VZ hardware: `tools/verify-live-sb2-shared-anon.sh`
(headless, `--screen` so the GPU arms `gpu_setup_ok` and WM REGISTER passes the
ENXIO guard). `SB2OWN.BIN` creates the shared surface (handle 1, one page),
writes `0xAB` through its WRITABLE leaf, handshakes the registered `SB2WM.BIN`
via the mailbox; the WM attaches by handle and reads `0xAB` through its EL0-RO
`sw_cow` leaf in ITS OWN root (`sb2: wm-read=0xAB`); the owner acks, sends
"bye", exits — the scheduler exit seam revokes the WM's RO view — and the WM's
stale re-attach returns `EFAULT` (`sb2: wm-reattach=EFAULT`). Full marker chain,
zero faults.

Bugs found and fixed during the live bring-up:
- **ESP root window 64→96** (`kernel/src/esp.zig`): the image's 68 root files
  (M30 dynamic-linker set + the SB2 proofs) exceeded the old cap and `exec`
  silently couldn't see the dropped tail entries — the gate's apps never ran.
- **WM REGISTER ENXIO**: without `--screen` the GPU never arms, so REGISTER
  refused; the gate now passes `--screen` like `verify-live-wmctl-register.sh`.
- **`sys_procs` row-count vs. byte-count**: the owner's scan loop compared
  `off + 40 <= n` where `n` is the ROW COUNT (3), never entering the loop;
  fixed to `<= n * 40` in both find helpers.
- **NUL-padded name column**: `std.mem.eql` on the 16-byte `row.name` never
  matched; added a NUL-trimming `name_matches`.
- **Marker newlines**: `write_marker` now terminates with `\n` so the runner's
  `--script-expect` matches whole lines.

Verification: `zig build` clean, full host suite green (583 aggregated tests
incl. the two syscall-level shared-anon proofs), fmt clean, coordination ok,
BSS PASS (10850408 B; the +1,536 B is the ESP window bump). Claim 8878 done.
