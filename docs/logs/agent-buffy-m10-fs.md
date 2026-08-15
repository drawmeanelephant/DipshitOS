# Log — milestone ten userland filesystem & storage ABI (claim 0662)

**Branch:** `agent/buffy/m10-fs`

- **2026-08-15** — *buffy*: claimed card F0 (storage contract & ADR 0010) under claim 0662; authored `docs/decisions/0010-userland-filesystem-abi.md`.
- **2026-08-15** — *buffy*: claimed card F1 (kernel file handle table) under claim 9948; implemented `kernel/src/file_table.zig` with unit tests and process lifecycle integration.
- **2026-08-15** — *buffy*: claimed card F2 (path routing & canonicalization) under claim 8313; implemented volume prefix routing and traversal defense in `kernel/src/file_table.zig`.
- **2026-08-15** — *buffy*: claimed card F3 (file syscall seam slots 23–27) under claim 3570; implemented `sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`, `sys_dir_list` in `kernel/src/syscall.zig` with full uaccess integration and unit test coverage.
- **2026-08-15** — *buffy*: claimed card F4 (userland storage utilities & live gate) under claim 0510; authored `SAVETEXT.BIN`, `TYPE.BIN`, `DIR.BIN`, embedded in disk image build pipeline, created and verified capstone live gate `tools/verify-live-user-fs.sh` on Apple Virtualization.framework across reboot. Milestone 10 complete!

