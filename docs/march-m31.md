# Milestone thirty-one march — dynamic linking ecosystem & userland migration (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M31's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

With Milestone 30 establishing the core dynamic linking foundation (freestanding
`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`, multi-aperture W^X isolation, and AuxV
protocol), Milestone 31 expands dynamic linking across the entire userland
ecosystem. This milestone focuses on migrating existing desktop and CLI applications
from static binary compilation to dynamic linking, reducing binary disk footprints,
enabling runtime plugin loading (`dlopen`/`dlsym`), and optimizing library startup.

## The cards

| # | Card | Status | Notes |
|---:|------|--------|-------|
| E1 | **Dynamic CALC (`CALC.ELF`).** Migrate calculator application to dynamic linking against `LIBUI.SO` and `LIBFONT.SO`. | ⬜ | Reduces binary size from ~68 KiB static down to lightweight dynamic executable. |
| E2 | **Dynamic NOTEPAD (`NOTEPAD.ELF`).** Migrate text editor to dynamic linking. | ⬜ | Tests multi-window and clipboard interaction over dynamically linked symbols. |
| E3 | **Dynamic FILE Manager (`FILE.ELF`).** Migrate file manager to dynamic linking. | ⬜ | Exercises mutating filesystem operations alongside shared UI widgets. |
| E4 | **Dynamic DESKTOP Shell (`DESKTOP.ELF`).** Migrate window manager / desktop composition shell to dynamic linking. | ⬜ | Validates multi-process desktop session running purely dynamic binaries. |
| E5 | **Userland Dynamic Plugin Loading (`dlopen` / `dlsym`).** Expose dynamic symbol resolution interface for runtime loadable modules. | ⬜ | Enables loadable skins, custom filters, and plugin extensions. |
| E6 | **Lazy Binding / PLT Trampolines.** Optional lazy relocation resolution for large shared libraries. | ⬜ | Defers symbol lookups until first function call via PLT jump stubs. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Application Migration** | `user/src/calc.zig`, `user/src/notepad.zig`, `user/src/file_browser.zig`, `user/src/desktop.zig` | M30 done (`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`). |
| **B — Dynamic Extensions** | `user/src/ld.zig` (`dlopen`/`dlsym` and PLT support). | M30 done. |
