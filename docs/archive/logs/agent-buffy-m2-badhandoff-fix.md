# Log — `agent/buffy/m2-badhandoff-fix` (PR #11)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `agent/buffy/m2-badhandoff-fix`):** claimed
  the bad-handoff gate fix. Disassembled the current kernel ELF
  (`.zig-cache/o/300f11f…/dipshit-kernel`): the naked `_start` shim sits at
  VMA 0 (matches `LOADER.TXT` `ram_first8`); its `bl kernel_main` at `0x30`
  clobbers LR to `0x34`, so the shim's final `ret` loops `0x34→0x38→0x34`
  instead of returning to the loader — the kernel can never reach the
  pre-exit `return bad_handoff` handoff, so `RC.TXT` is never written. Fix:
  save the loader's LR in a callee-saved register (x20, preserved by
  `kernel_main` under AAPCS64) before the `bl`, restore it before `ret`. 🔄
  in progress — before/after gate evidence to follow.
- **2026-08-06** — **Bad-handoff gate fixed (buffy,
  `agent/buffy/m2-badhandoff-fix`):** root cause confirmed as the naked
  `_start` shim clobbering LR (above). Implemented the two-instruction fix
  in `kernel/src/main.zig`; disassembly now shows `mov x20, x30` at shim
  offset `0x14` and `mov x30, x20` at `0x3c` around `bl kernel_main`.
  **Observed:** `verify-bad-handoff.sh` exits 0 and `RC.TXT` =
  `kernel_rc=0x0000000000000002` (`artifacts/m2-badhandoff-fix-after.txt`);
  all build gates green (`m2-badhandoff-fix-gates.txt`); good path
  unregressed — `zig build run` reaches the same state as before (loader
  evidence present, `vm-serial.log` empty, kernel never returns,
  `m2-badhandoff-fix-goodpath.txt`). The VZ serial gate remains a separate
  open question. ✅
- **2026-08-06** — **Parallel-agent prompt docs (buffy,
  `agent/buffy/m2-badhandoff-fix`):** added
  `docs/m15-host-plumbing-prompt.md` (agent A, M1.5 steps 4–7: duplex
  serial attachment, live teeing, terminal safety, `zig build console`) and
  `docs/m15-commands-prompt.md` (agent C, M1.5 steps 12–18: registry,
  identity/memory/utility/control commands, personality — mock-console
  based, new kernel files only). Links added to the Active claims table.
  Both are unclaimed and ready to run in parallel with the VZ serial gate
  (`docs/m2-vz-serial-gate-prompt.md`). ✅ written — no implementation
  started.
