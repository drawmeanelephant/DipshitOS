# Log — `agent/buffy/fix-boot-fat-geometry`

## 2026-08-25 — #552 resolved not-a-bug; sysinfo D9 gate simplified to fresh boot

Follow-up to claim 5220's D9 verification. A raw-serial probe on a fresh
boot shows `sysinfo` printing storage `free=0x4f14800/0x5991600` with NO
`mount esp` first — the earlier "missing free=/total" report was a gate
grep artifact: the one-shot boot debug line (`syscall: write ok n=23`)
interleaves mid-print and splits the storage line across serial lines.
Additionally, `stat /KERNEL.BIN` walks the FAT32 root directory
pre-mount, which requires valid cluster geometry — so boot-time FAT state
was never empty.

Changes:
- `tools/verify-live-sysinfo.sh`: dropped the `mount esp` workaround;
  asserts the unanchored `free=0x…/0x…` shape on a fresh boot.
  Re-run: PASS 1/1 on VZ (evidence in `artifacts/live-sysinfo-*`).
- `docs/march-m22.md`: D9 row records the not-a-bug resolution.

No kernel or userland code changes. Closes #552 via PR.
