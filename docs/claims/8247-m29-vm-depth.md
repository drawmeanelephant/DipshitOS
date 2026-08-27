# Claim: M29 VM Depth: Demand Paging, Copy-on-Write (COW), and Anonymous mmap

- **Owner:** buffy (`agent/buffy/m30-dynamic-linking`)
- **Prompt / plan:** https://github.com/drawmeanelephant/DipshitOS/issues/598
- **Scope:** Milestone 29 — VM Depth: demand paging (zero-fill translation faults), Copy-on-Write (COW permission faults), anonymous sys_mmap / sys_munmap (slots 63/64), process dynamic memory tracking, and class-B live hardware gate
- **Touches:** kernel/src/alloc.zig, kernel/src/exceptions.zig, kernel/src/mmu.zig, kernel/src/process.zig, kernel/src/syscall.zig, kernel/src/uaccess.zig, user/src/lib/ui.zig, user/src/vmtest.zig, build.zig, image/make-image.sh, image/mkfat32.py, tools/verify-live-vm-depth.sh, docs/march-m29.md, docs/status.md
- **Depends on:** —
- **Heartbeat:** 2026-08-27
- **Status:** ✅ done

## Notes

Milestone 29 brings deep virtual memory management to DipshitOS (Issue #598):
1. Demand Paging: zero-fill Data Abort translation & unmapped permission faults (`EC_DATA_ABORT_LOWER`) allocated on touch.
2. Copy-on-Write (COW): shared physical memory pages with permission fault handling (`DFSC=0xc..0xf`) on write.
3. Anonymous `sys_mmap` and `sys_munmap` (ABI slots 63 and 64): userland on-demand dynamic memory mapping.
4. Clean process memory tracking and zero-leak reclamation on exit/reap.
5. Class-A unit tests and Class-B live hardware gate `tools/verify-live-vm-depth.sh` (1/1 boot verified live on Apple Silicon VZ hardware).
