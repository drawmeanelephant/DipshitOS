# Claim: M31 Dynamic Linking Ecosystem & Userland Migration

- **Owner:** buffy (`agent/buffy/m30-dynamic-linking`)
- **Prompt / plan:** Milestone 31 — Dynamic Linking Ecosystem & Userland Migration (docs/march-m31.md)
- **Scope:** Milestone 31: Migrate desktop applications (CALC.ELF, NOTEPAD.ELF, FILE.ELF, DESKTOP.ELF) to dynamic linking against LIBUI.SO and LIBFONT.SO, implement userland dlopen/dlsym runtime plugin loading in LD.SO, integrate into FAT32 image, and verify with Class-B live hardware gate.
- **Touches:** tools/mkdyn-elf.py, user/src/ld.zig, image/apps.txt, image/make-image.sh, image/mkfat32.py, tools/verify-live-dynamic-ecosystem.sh, docs/march-m31.md, docs/status.md
- **Depends on:** 7921 (Milestone 30)
- **Heartbeat:** 2026-08-27
- **Status:** PASSED ✅

## Notes

Milestone 31 expands dynamic linking across the userland application ecosystem (Issue #599 / docs/march-m31.md):
1. Expand `LIBUI.SO` and `LIBFONT.SO` shared library APIs.
2. Generate lightweight dynamic ELF executables: `CALC.ELF`, `NOTEPAD.ELF`, `FILE.ELF`, `DESKTOP.ELF`.
3. Implement `dlopen` and `dlsym` dynamic plugin loading in `LD.SO` with loadable plugin `PLUGIN.SO`.
4. Embed all dynamic ELFs into the FAT32 disk image (`disk.img`) and register in `APPS.TXT`.
5. Class-B live hardware gate `tools/verify-live-dynamic-ecosystem.sh` asserting all dynamic executables run cleanly without crashes (1/1 boot passed across 5 dynamic executables).
