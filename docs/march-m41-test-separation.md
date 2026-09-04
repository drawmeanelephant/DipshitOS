# Milestone forty-one march — in-tree test separation & source de-monolithization (living tracker)

> [`docs/status.md`](status.md) is the canonical milestone-level source. This
> file holds M41's per-card detail, order, and gate notes. A card's row flips
> to ✅ only with real observed evidence.
> Umbrella issue: **#951** (M41: In-Tree Test Separation & Source De-monolithization).
> GitHub milestone: **28 — M41: In-Tree Test Separation & Source De-monolithization**.

## Where we are

As VirelaiOS expanded across 40 milestones, source modules accumulated extensive
in-line unit test suites directly inside implementation files. Several core
components became massive monoliths:
- `kernel/src/syscall.zig` grew to over 5,600 lines (more than 2,750 lines of tests)
- `kernel/src/driving_award.zig` grew to over 5,600 lines
- `user/src/lib/ui.zig` holds over 4,900 lines
- `kernel/src/shell.zig`, `kernel/src/scheduler.zig`, and others contain thousands of lines mixing implementation and test harnesses
- Furthermore, test execution relied on a sequential loop in `tools/verify-unit-tests.sh` running 45+ separate `zig test` invocations, and test authors repeatedly duplicated mock logic for user memory, vector frames, event queues, and framebuffer scanouts.

M41 extracts unit tests into clean dedicated test files, modularizes oversized
source files, provides a shared mock library, and unifies host test execution
under `zig build test` running concurrently.

## The cards, in order

> **TS1 unified test architecture & mocks → TS2 UI test extraction & widget decomposition → TS3 syscall & scheduler test decoupling → TS4 shell & monitor modularization → TS5 compositor & networking test separation → TS6 harness cutover & closeout.**

| Card | Issue | Phase | Depends on | Status | Touches | Notes |
|:-----|:------|:------|:-----------|:-------|:--------|:------|
| **TS1** | [#952](https://github.com/drawmeanelephant/DipshitOS/issues/952) **Unified Test Architecture & Shared Mock Library** | foundation | — | ✅ done 2026-09-04 | `build.zig`, `test/helpers/*`, `docs/march-m41-test-separation.md` | Added parallel `zig build test` step running all host unit tests concurrently (53/53 tests pass). Created shared `test/helpers/` mock library (`uaccess_mock`, `task_mock`, `event_mock`, `fb_mock`, `helpers`). |
| **TS2** | [#953](https://github.com/drawmeanelephant/DipshitOS/issues/953) **UI Test Extraction & Widgets Decomposition** | userspace | TS1 (#952) | ✅ done 2026-09-04 | `user/src/lib/ui.zig`, `user/src/lib/ui/widgets.zig`, `user/src/lib/ui/widgets/*`, `user/tests/ui/ui_test.zig`, `build.zig`, `docs/march-m41-test-separation.md` | Decomposed `widgets.zig` (1,740 -> 70 lines) into 9 granular submodules under `user/src/lib/ui/widgets/`. Extracted 1,449 lines of UI tests into `user/tests/ui/ui_test.zig`, dropping `ui.zig` from 1,823 to 370 lines. Wired to `zig build test` (6,581+ tests pass). 100% backward compatibility preserved. |
| **TS3** | [#954](https://github.com/drawmeanelephant/DipshitOS/issues/954) **Syscall & Scheduler Test Decoupling** | kernel | TS1 (#952) | ✅ done 2026-09-04 | `kernel/src/syscall.zig`, `kernel/src/scheduler.zig`, `kernel/tests/syscall_test.zig`, `kernel/tests/scheduler_test.zig`, `build.zig`, `docs/march-m41-test-separation.md` | Decoupled 56 syscall unit tests (2,871 lines removed from `syscall.zig`, 5,748 -> 2,877 lines) into `kernel/tests/syscall_test.zig` (2,993 lines) and 33 scheduler unit tests (1,022 lines removed from `scheduler.zig`, 3,527 -> 2,505 lines) into `kernel/tests/scheduler_test.zig` (1,094 lines). Wired both suites to `zig build test` using shared `test/helpers/task_mock.zig`. 100% pass across all 114 test steps / 4,947+ tests. |
| **TS4** | [#955](https://github.com/drawmeanelephant/DipshitOS/issues/955) **Shell & Monitor Test Decoupling & Builtins Modularization** | kernel | TS1 (#952) | ⏳ ready | `kernel/src/shell.zig`, `kernel/src/monitor.zig`, `kernel/src/commands/*` | Modularize monitor/shell built-in command dispatchers, extract shell and monitor unit tests into dedicated suites. |
| **TS5** | [#956](https://github.com/drawmeanelephant/DipshitOS/issues/956) **Compositor & Networking Protocol Test Separation** | kernel | TS1 (#952) | ⏳ ready | `kernel/src/driving_award.zig`, `kernel/src/tcp.zig`, `kernel/src/dhcp.zig`, `kernel/src/alloc.zig` | Extract window manager, TCP, DHCP, and heap allocator tests into decoupled test suites. |
| **TS6** | [#957](https://github.com/drawmeanelephant/DipshitOS/issues/957) **Gate Harness Cutover, Verification & Milestone Closeout** | closeout | TS2–TS5 | ⏳ pending | `tools/verify-unit-tests.sh`, `justfile`, documentation | Modernize `verify-unit-tests.sh` to delegate to `zig build test`, ensure 100% test coverage preserved, update living documentation. |

## Invariants & Design Principles

1. **Zero-Regression Contract**: Every single existing test assertion must remain
   100% green at every step. Total test count must not decrease.
2. **Backward Compatibility**: Public symbols, structs, and functions exposed by
   `ui.zig`, `syscall.zig`, `shell.zig`, etc., must remain 100% source-compatible.
3. **Freestanding Purity**: Production kernel and userspace binaries (`KERNEL.BIN`,
   `USER.BIN`, `WND.BIN`, `TABWM.BIN`) must remain strictly freestanding, zero libc,
   zero allocation in core paths, with no test code compiled into production artifacts.
4. **Fast Parallel Execution**: Host tests run concurrently via the native `zig build test`
   pipeline with reproducible outputs.
