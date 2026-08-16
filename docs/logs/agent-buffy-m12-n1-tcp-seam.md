# Log — Milestone 12 Card N1: userland TCP syscall seam

- **Branch:** `agent/buffy/m12-n1-tcp-seam`
- **Claim:** [`docs/claims/7483-n1-tcp-syscall-seam.md`](../claims/7483-n1-tcp-syscall-seam.md)
- **Scope:** Milestone 12 Card N1 (Issue #148: userland TCP syscall seam)

## Entries

- **2026-08-15:** Started Card N1. Created branch `agent/buffy/m12-n1-tcp-seam` and filed claim 7483.
- **2026-08-15:** Completed Card N1. Implemented syscall slots 30–33 (`sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close`) and slot 29 (`sys_kill`), created proof binary `TCP.BIN`, updated `build.zig`, `mkfat32.py`, and `make-image.sh`, and added Class-B test runner `tools/verify-live-net-tcp-syscall.sh`. All unit tests and live VZ gate PASS.
