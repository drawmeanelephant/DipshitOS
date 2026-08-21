# Claim: Milestone 12 Card N1 — userland TCP syscall seam

- **Owner:** buffy (`agent/buffy/m12-n1-tcp-seam`)
- **Prompt / plan:** `docs/march-m12.md`
- **Scope:** Milestone 12, Card N1 (Issue #148: userland TCP syscall seam)
- **Depends on:** Milestone 11 (`main`), Issue #148
- **Status:** ✅ done

## Notes

Implements ADR 0007 / ADR 0012 syscall slots 30–33:
- `sys_tcp_connect` (slot 30): initiates 3-way handshake to target IPv4:port
- `sys_tcp_send` (slot 31): transmits up to 64 bytes via uaccess copy_in
- `sys_tcp_recv` (slot 32): drains oldest RX segment via uaccess copy_out
- `sys_tcp_close` (slot 33): initiates clean FIN teardown

Adds proof program `TCP.BIN` (`user/src/tcp_client.zig`) and Class-B live gate
`tools/verify-live-net-tcp-syscall.sh`.

## Evidence

- Unit tests: `bash tools/verify-unit-tests.sh` passes across all 34 modules.
- Live VZ gate: `bash tools/verify-live-net-tcp-syscall.sh` passes (`PASS`, exit 0).
  - Program connected to `10.0.0.2:9999`, sent `hello`, received echo `tcp: got echo hello`, and exited status 18.
  - Syscall table updated to 34 implemented slots; call counts recorded for slots 30..33.
  - Evidence in `artifacts/live-net-tcp-syscall-gate.txt` and `artifacts/live-net-tcp-syscall-report.txt`.
