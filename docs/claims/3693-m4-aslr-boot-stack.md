# Claim: extend ASLR to the boot-time static EL0 payload (claim 2665 follow-on)

- **Owner:** Buffy (`agent/buffy/m4-entropy-csprng`)
- **Prompt / plan:** user follow-on to claim 2665 (milestone four card 1):
  *extend ASLR to the boot-time static EL0 payload — rebuild the user root
  post-seed with a randomized stack VA (update live-addrspaces accordingly)
  so every EL0 task, not just exec'd ones, gets per-boot stack placement.*
- **Scope:** the boot-time half of the seed's ASLR consumer. After the
  claim-2665 seed (post-MMU, post-allocator), rebuild the EL0 user root
  with `csprng.random_stack_va()` and switch the boot path seams to it:
  `userspace.bss_user_va` uses the current stack VA (so `register_user`'s
  sp_el0 + timer-preemption witness follow the randomized base),
  `syscall.set_user_regions` is re-armed, and an `aslr: boot user stack=0x…`
  line gives host-visible per-boot evidence. `cmd_addrspaces` already
  reports `userspace.user_stack_va()` (claim 2665), so it shows the
  randomized placement; the `live-addrspaces` gate's exact-stack-VA
  assertion is updated to validate the ASLR band instead (text VA stays
  fixed, stack VA ∈ [0x1000_0000, 0x8000_0000), 64 KiB aligned, ≠ text_va).
  The `live-entropy` gate additionally asserts the boot stack VA differs
  across its two boots. Unseeded (fallback) boots skip the rebuild and keep
  the fixed stack — behavior unchanged.
- **Depends on:** claim 2665 (seeded CSPRNG, `random_stack_va`,
  `userspace.set_stack_va`/`user_stack_va`, exec-path ASLR) — same branch,
  PR #69 absorbs this commit.
- **Status:** ✅ done 2026-08-10 (closed; branch `agent/buffy/m4-entropy-csprng`, follow-on PR)

## Notes

**Why it matters:** claim 2665's ASLR consumer only covered exec'd programs
(the runtime rebuild); the boot-time static EL0 payload still ran on the
fixed `0x8000_0000` stack, so the very first EL0 task was not randomized.
Rebuilding the root post-seed is proven safe by the exec path (claim 6783:
the kernel stays identity-mapped, so post-install `build_user_root` +
`clean_table_storage` works); the 1 MiB table carve-out has ample room for
one extra clone at boot.

**Same relative layout:** the witness/stack offsets inside `.userbss` are
base-relative; changing only the base preserves every relationship, so the
boot payload's stack growth, the timer-preemption witness, and sp_el0 all
keep working at any 64 KiB-aligned base in the ASLR band.

## Verification

- **Class A:** fmt, unit tests (userspace `bss_user_va` follows the current
  VA — host tests keep the fixed default), transcript byte-identical (no
  fixture change — `addrspaces` is not in the mock session), build/image/
  inspect, coordination, mmu-debt.
- **Class B on VZ:** `verify-live-addrspaces.sh` UPDATED (stack VA asserted
  in-band/aligned instead of the exact fixed value); `verify-live-entropy.sh`
  extended (boot stack VA differs across boots); regressions: userspace,
  svc, uaccess, exec, sleep, lifecycle (the boot payload now runs on the
  randomized stack in every one of these).
- **Evidence:** `artifacts/live-addrspaces-*`, `artifacts/live-entropy-*`.
