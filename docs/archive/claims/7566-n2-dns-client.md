# Claim: Milestone 12 Card N2 — bounded DNS client

- **Owner:** buffy (`agent/buffy/m12-n2-dns-client`)
- **Prompt / plan:** `docs/march-m12.md`
- **Scope:** Milestone 12, Card N2 (Issue #149: bounded DNS client)
- **Depends on:** Milestone 12 Card N1 (`7483-n1-tcp-syscall-seam.md`), Issue #149
- **Status:** ✅ done

## Notes

Implements RFC 1035 UDP DNS resolution client in `kernel/src/dns.zig`:
- Query builder: standard A-record query for hostname with 16-bit transaction ID, RD=1, QTYPE=1 (A), QCLASS=1 (IN).
- Response parser: handles header flags, skips question section, parses answers (supports direct name and RFC 1035 compression pointers), extracts 4-byte IPv4 address.
- State machine & timeout: tracks query lifecycle (`.idle`, `.query_sent`, `.resolved`, `.failed`) with 5 s timeout.
- Monitor integration: `net dns <hostname> [server-ip]` command in `kernel/src/monitor.zig`.
- Host responder: `--net-dns-respond <ip:port>` in `host/vm-runner/Sources/VMRunner/main.swift`.
- Class-B verification gate: `tools/verify-live-net-dns.sh`.

## Evidence

- Unit tests: `bash tools/verify-unit-tests.sh` passes across all 35 modules.
- Live VZ gate: `bash tools/verify-live-net-dns.sh` passes (`PASS`, exit 0).
  - Resolved `example.com` -> `93.184.216.34` and `myhost.local` -> `10.0.0.2`.
  - DNS statistics recorded: `dns=resolved,q=2,r=2,err=0,timeout=0`.
  - Evidence in `artifacts/live-net-dns-gate.txt` and `artifacts/live-net-dns-report.txt`.
