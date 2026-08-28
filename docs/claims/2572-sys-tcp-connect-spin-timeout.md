# Claim: sys_tcp_connect drain spin timeout fix

- **Owner:** buffy (`agent/buffy/issue-613-tcp-connect-spin`)
- **Prompt / plan:** `https://github.com/drawmeanelephant/DipshitOS/issues/613`
- **Scope:** Milestone 5 (N10) / Milestone 12 (N1) TCP syscall connect timeout
- **Touches:** `kernel/src/syscall.zig`, `kernel/src/timer.zig`, `tools/verify-live-net-tcp.sh`, `tools/verify-live-net-tcp-syscall.sh`, `docs/claims/2572-sys-tcp-connect-spin-timeout.md`, `docs/logs/agent-buffy-issue-613-tcp-connect-spin.md`
- **Depends on:** —
- **Heartbeat:** 2026-08-28
- **Status:** ✅ agent/buffy/issue-613-tcp-connect-spin

## Notes

Closes Issue #613: `handle_tcp_connect` in `kernel/src/syscall.zig` previously used a tight 1,000,000-iteration loop polling `virtio_net.net_rx_drain()`. On Apple Silicon, 1M empty drain iterations exhaust in ~10–20 ms, racing host VZ delivery of the SYN-ACK frame and prematurely returning `EINVAL`.

This change bounds the connect wait by real wall-clock time using `CNTPCT_EL0` via `timer.cntpct()`, drives `tcp.poll_rto()` for SYN retransmissions, enforces the 30-second `tcp.connect_timeout` contract, inserts a light spin delay to avoid bus contention, and ensures clean connection state teardown on failure/timeout.
