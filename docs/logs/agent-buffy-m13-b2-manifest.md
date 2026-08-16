# Branch log — agent/buffy/m13-b2-manifest (claim 8877)

## 2026-08-16 — branch opened

- Card B2 of Milestone 13 (issue #152): application identity manifest.
- Plan: APPS.TXT on the ESP, embedded by the image build; DESKTOP.BIN
  reads + parses it at startup via the M10 file seam, falling back to the
  hardcoded array when the manifest is missing.
- Branch based on `origin/main` (M12 merged as `9b447eb` via PR #160).

## 2026-08-16 — branch work

- Claim 8877 implementation complete: APPS.TXT manifest + DESKTOP.BIN
  parse/fallback + live gate assertions (`DESKTOP.MANIFEST: OK`,
  `DESKTOP.LAUNCH: OK`).
- **Root-cause hunt (the long tail):** the live desktop gate initially
  showed `desktop: manifest apps=8` CORRUPTED (first 15 bytes replaced by
  `NUL×8 + 0x01 + NUL×6`). Two real bugs were found and fixed:
  1. **Kernel-stack overflow (pre-existing):** exec allocates
     text/stack/kstack as adjacent heap regions; the EL0 `sys_file_read`
     path (2×2048 staging + FAT buffers) overflowed the 8 KiB kstack
     DOWNWARD into the user stack, spraying FAT bytes into DESKTOP's
     AppState (the buttons showed `"CALC    "` = FAT 8.3 short names).
     Fixed by doubling `scheduler.task_stack_size` 8 KiB → 16 KiB;
     exec.zig page accounting updated (9 pages/exec: 1 text + 4 stack +
     4 kstack).
  2. **FP/SIMD clobber across exceptions (pre-existing):** the vector
     stubs saved only GPRs, so the kernel's NEON (ReleaseSmall memcpy)
     destroyed EL0 FP state live across an `svc` — DESKTOP's marker build
     hoisted `ldr q0` before `svc` and reused it after. Fixed properly in
     the vector stubs: every stub now branches to a shared `exc_fp_common`
     that pushes q0–q31 (512 B) below the GPR frame and pops them on
     restore; `build_initial_frame` reserves the same zeroed block.
     `exceptions.fp_save_bytes` documents the layout; the C-visible
     `VectorFrame` is byte-identical. The `[EXC]` report gained an
     sp/x1/x2/x29 diagnostic line (kept — it cracked this bug).
- **Stale gate assertions fixed** (pre-existing rot from M11/M12 syscall
  growth + the 16 KiB stack bump): `implemented=12/21/23` → 34 in
  sleep/net-udp-syscall/win-close/win-move/win-syscall; `exec:` → `error:`
  prefix on the pool-full line in args/ipc/scale; the `connect refused`
  prefix in net-tcp; 5-page → 9-page accounting in kill/long-lived.
- **Live verification:** full 43-gate VZ sweep green except
  `verify-live-glyphs`, which fails 8/666 unknowns even with ALL branch
  changes stashed — a **pre-existing M11/M12 window-manager regression**
  (terminal window content renders one cell right of origin with stale
  residue at cell 0; gate last passed 2026-08-14 pre-M11). Filed as an
  issue; desktop gate + all other live gates PASS.
