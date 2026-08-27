# Claim: M30 Dynamic Linking: Freestanding Runtime Linker & Shared Libraries (libui.so)

- **Owner:** buffy (`agent/buffy/m30-dynamic-linking`)
- **Prompt / plan:** https://github.com/drawmeanelephant/DipshitOS/issues/599
- **Scope:** Milestone 30 — dynamic ELF loader enhancements, freestanding dynamic linker LD.SO, shared libraries LIBUI.SO / LIBFONT.SO, and class-B live hardware gate
- **Touches:** kernel/src/elf.zig, kernel/src/exec.zig, kernel/src/mmu.zig, kernel/src/process.zig, kernel/src/scheduler.zig, kernel/src/syscall.zig, kernel/src/uaccess.zig, user/src/ld.zig, user/src/libui_so.zig, user/src/libfont_so.zig, user/src/dynapp.zig, user/ld.ld, user/dyn.ld, user/so.ld, build.zig, image/apps.txt, image/make-image.sh, image/mkfat32.py, tools/mkdyn-elf.py, tools/verify-live-dynamic-linking.sh, docs/march-m30.md, docs/march-m31.md, docs/status.md
- **Depends on:** —
- **Heartbeat:** 2026-08-27
- **Status:** ✅ agent/buffy/m30-dynamic-linking

## Notes

Milestone 30 introduces dynamic ELF linking and shared library support to DipshitOS (Issue #599).
1. Kernel ELF Dynamic Loader: parses PT_DYNAMIC, PT_INTERP, constructs Aux Vector on user stack, enters LD.SO.
2. Freestanding AArch64 Dynamic Linker: zero-libc, zero-POSIX LD.SO resolves R_AARCH64_RELATIVE, R_AARCH64_GLOB_DAT, R_AARCH64_JUMP_SLOT.
3. Core Shared Libraries: LIBUI.SO and LIBFONT.SO compiled as position-independent shared ELF libraries.
4. Class-A Unit Tests and Class-B Live Hardware Gate `tools/verify-live-dynamic-linking.sh` passing (banner=1 listed=1 loaded=1 ld_init=1 dyn_run=1 exited=1 reaped=1 echo_ok=1 fatal=0).
