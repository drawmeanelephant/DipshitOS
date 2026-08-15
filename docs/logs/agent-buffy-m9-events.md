# Log — milestone nine interactive application events (claim 7463)

**Branch:** `agent/buffy/m9-events`

- **2026-08-15** — *buffy*: claimed card E0 (event contract & ADR 0009) under claim 7463; authored `docs/decisions/0009-application-events.md`.
- **2026-08-15** — *buffy*: claimed card E1 (kernel per-process event queue) under claim 7670; implemented `kernel/src/events.zig` with unit tests.
- **2026-08-15** — *buffy*: claimed card E2 (keyboard event routing) under claim 7206; integrated keyboard routing in `kernel/src/input.zig` and `kernel/src/driving_award.zig`.
- **2026-08-15** — *buffy*: claimed card E3 (pointer & click event routing) under claim 9228; integrated pointer motion and click routing in `kernel/src/driving_award.zig`.
- **2026-08-15** — *buffy*: claimed card E4 (window lifecycle events) under claim 0293; implemented WIN_FOCUS, WIN_BLUR, and WIN_CLOSE events in `kernel/src/driving_award.zig`.
- **2026-08-15** — *buffy*: claimed card E5 (event syscall seam) under claim 1016; implemented sys_poll_event and sys_wait_event in `kernel/src/syscall.zig` and `kernel/src/scheduler.zig`.
- **2026-08-15** — *buffy*: claimed card E6 (first interactive EL0 application KEYTEST.BIN & capstone gate) under claim 9328.
- **2026-08-15** — *buffy*: completed card E6; authored `user/src/keytest.zig` (KEYTEST.BIN) and capstone gate `tools/verify-live-events.sh`; embedded in ESP image and verified on live Virtualization.framework hardware. Milestone 9 complete.
