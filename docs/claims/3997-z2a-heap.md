# Claim: z2a-heap

- **Owner:** buffy (`agent/buffy/z2a-heap`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #756)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z2a: Heap)
- **Touches:** kernel/src/syscall.zig, user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z2a-heap.z, docs/claims/3997-z2a-heap.md, docs/logs/agent-buffy-z2a-heap.md
- **Depends on:** 1840
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Implement Z2a — `sys_mmap` (slot 63) + a bounded bump arena exposed through
the prelude — with a fixture that reads a file into a heap-built string and
writes it back byte-exact.

- `zc.mmap(len)` guest builtin in `user/src/zc.zig` (slot 63; prot RW = 3,
  flags MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE = 0x8022, so the eager
  allocation lets kernel-side file copies touch the heap).
- Prelude shim `user/src/lib/zc.zig`: `mmap`, plus pointer-form
  `file_read`/`file_write`/`file_close` and a u64-returning `file_open` — the
  in-guest register ABI is (fd, ptr, count) with no slice indirection, and
  negative errnos surface as huge u64s.
- **Kernel fix (root cause of the whole EFAULT class):** `handle_mmap` armed
  the new region only into the transient uaccess lists, but `handle_svc`
  re-arms uaccess from the task TCB extras at EVERY svc entry — so a heap
  region vanished before the next syscall and any kernel copy_in/copy_out of
  mmap'd memory EFAULTed. `sys_mmap` now also registers the region in the
  task TCB (`scheduler.add_task_{read,write}_region`), matching what exec.zig
  always did. No prior consumer did kernel-side copies into mmap'd memory,
  which is why nothing caught it.
- Fixture `tests/zc-corpus/z2a-heap.z`: reads DATA.TXT (2500 B) in ≤1 KiB
  chunks into a 16 KiB mmap arena and writes OUT.TXT back byte-exact. Kernel
  file reads cap at 2048 B/call and writes >2048 B are refused, so the round
  trip loops. Every read lands in a dedicated 1 KiB landing zone at the arena
  head (the dialect's file_read needs a plain base pointer — no heap+offset
  arithmetic), each fresh chunk is append-copied to the bump offset, then the
  file is compacted to `heap[0..used]` and drained in ≤2048 B writes shifting
  the tail down. Bounded: overflow exits 2; an empty read exits 73 (vs 72 for
  a completed round trip). Kept under 2048 bytes: ZC.BIN reads its source
  with a SINGLE file_read (kernel cap 2048 B/call), so longer sources are
  silently truncated — the 2366-byte first landing-zone fixture failed
  in-guest at line 52, byte 2049, while host `zig 0.16` accepted it (that
  divergence is what identified the single-read cap).
- Gate `tools/verify-live-zc.sh`: MAIN.Z + a 2500 B patterned DATA.TXT are
  seeded host-side; phase 1 is `strace exec ZC.BIN` (asserting the full
  1838-byte source read `sys_file_read(...) = 0x72e`, which also guards the
  truncation regression), phase 2 `exec MAIN.ELF`; the host then `cmp`s
  OUT.TXT against DATA.TXT byte-for-byte and keeps OUT.TXT as evidence.
- Six clean live boots of the final gate shape (3/3 in the last run; every
  assertion incl. fileeq=1, fullread=1). New host unit tests (32/32).
- **Latent kernel-shell race found (NOT this card's bug, worth its own
  card):** plain `exec ZC.BIN` + `exec MAIN.ELF` is flaky — ~half of boots
  die with the shell faulting inside `shell.boot_and_park`'s idle loop (kernel
  text at 0x7da77000; elr 0x7da7fd44/0x7da7ff54 = offsets 0x8d44/0x8f54)
  dereferencing corrupted callee-saved registers (far 0x6/0x1e/garbage, states
  differ per boot). The exit-report ring (`process.zig push_exit_report` /
  `take_exit_report`) vs the idle-loop drain looks like the shared state.
  Tracing ZC.BIN only (synchronous per-syscall console prints) paces the
  phase so the gate is reliable; tracing MAIN.ELF too makes it worse.

Verified: host `zig 0.16` compile checks (all nine corpus fixtures, incl.
z2a-heap.z); `verify-live-zc.sh` PASS 3/3 (compiled=1 loaded=1 printed=1
exit72=1 fileeq=1 fullread=1 fatal=0); full monitor unit suite;
`verify-bss-budget.sh` PASS (541 960 B headroom).
