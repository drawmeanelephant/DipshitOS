# ADR 0012: Userland Network Applications, Socket ABI, and DNS Resolution

Status: **accepted** · Date: 2026-08-15 · Milestone: twelve (userland network applications)

## Context

Milestones zero through eleven delivered a fully operational, freestanding AArch64 operating system on Apple silicon:
- Preemptive multitasking and per-process virtual address spaces (Milestones 3 & 4)
- Virtio-net networking with ARP, IPv4/ICMP, UDP, DHCP, and TCP in the kernel (Milestone 5)
- Virtio-gpu window manager (Driving Award) and Road Pops terminal (Milestone 6)
- USB xHCI / HID keyboard and pointer input (Milestone 7)
- Human interface guidelines, line editing, and system diagnostics (Milestone 8)
- Interactive EL0 application events (Milestone 9, ADR 0009)
- Userland persistent storage ABI (Milestone 10, ADR 0010)
- Desktop environment, micro-widget UI toolkit, and consumer GUI applications (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`, `DESKTOP.BIN`) with `sys_exec` (slot 28) and `sys_kill` (slot 29) (Milestone 11, ADR 0011)

While Milestone 5 provided the kernel-level network transport (virtio-net, ARP, IPv4, UDP, DHCP, TCP client) and exposed UDP via syscall slots 9–11 (`sys_udp_listen`, `sys_udp_send`, `sys_udp_recv`), **TCP and hostname resolution remain inaccessible to EL0 userland applications**.

Milestone twelve turns DipshitOS into a **connected network platform** (Issues #148, #149, #150) by establishing:
1. The userland TCP syscall seam (ADR 0007 slots 30–33: `sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close`).
2. An RFC 1035 DNS resolution client in the kernel / userland (`kernel/src/dns.zig` / `user/src/lib/dns.zig`).
3. Standalone network applications: `TCP.BIN` (TCP protocol proof), `FETCH.BIN` (HTTP/1.0 web client), and `CHAT.BIN` (graphical peer-to-peer chat application).

---

## Decisions

### D1. TCP Syscall ABI & State Model (ADR 0007 Slots 30–33)

Following the UDP seam pattern (slots 9/10/11, card N6), TCP is exposed to EL0 through four dedicated syscall slots operating on the kernel's bounded TCP client (`kernel/src/tcp.zig`):

| Slot | Name | Signature | Description |
|:---|:---|:---|:---|
| 30 | `sys_tcp_connect` | `connect(ip: u32, port: u16) -> i64` | Resolves peer MAC via ARP, initiates TCP 3-way handshake (SYN), and blocks the caller on the scheduler sleep/event seam until `ESTABLISHED` or timeout (30 s). Returns `0` on success, or negative error code (`ECONNREFUSED` -6, `ETIMEDOUT` -7, `EINVAL` -1, `ENOTREADY` -5). |
| 31 | `sys_tcp_send` | `send(buf_ptr: [*]const u8, len: usize) -> i64` | Marshals payload up to 64 bytes (`payload_max`) through `uaccess.copy_in`, constructs TCP segment, and transmits. Returns bytes sent, or negative error code (`ENOTCONN` -5, `EFAULT` -3, `EINVAL` -1). |
| 32 | `sys_tcp_recv` | `recv(buf_ptr: [*]u8, max_len: usize) -> i64` | Drains the RX buffer via `uaccess.copy_out` (peek $\to$ copy $\to$ pop). Drains virtio-net device first (polled-drain contract). Returns bytes copied (0 if empty / non-blocking EOF), or negative error code (`ENOTCONN` -5, `EFAULT` -3). |
| 33 | `sys_tcp_close` | `close() -> i64` | Initiates graceful FIN handshake (FIN $\to$ FIN-ACK $\to$ ACK) and transitions connection to `closed`/`idle`. Returns 0 on success, or negative error code (`ENOTCONN` -5). |

#### Lifecycle & Ownership Invariants
1. **Bounded State Machine:**
   Single active TCP client connection at a time in `kernel/src/tcp.zig` (zero heap allocation, static BSS).
2. **Automatic Teardown on Exit:**
   On process termination (`scheduler.exit_current`), if the exiting PID owns an active TCP connection, the kernel resets or cleanly tears down the connection to prevent orphan socket state.

---

### D2. Bounded DNS Client (RFC 1035 Resolver)

Hostname resolution is implemented as a bounded RFC 1035 UDP client (`kernel/src/dns.zig` / `user/src/lib/dns.zig`):

1. **Transport:**
   Operates via UDP to port 53 targeting a configured resolver IP (e.g. gateway `192.168.64.1` under NAT or configurable via `net dns-server <ip>`).
2. **Wire Format Encoding:**
   - Standard 12-byte DNS Header:
     - `ID`: 16-bit transaction identifier from CSPRNG / counter.
     - `Flags`: `0x0100` (Standard query, Recursion Desired = 1).
     - `QDCOUNT`: 1 (Single question).
     - `ANCOUNT`: 0, `NSCOUNT`: 0, `ARCOUNT`: 0.
   - Question Section:
     - QNAME: Dot-separated label sequence (e.g. `example.com` $\to$ `\x07example\x03com\x00`).
     - QTYPE: `0x0001` (Type A — IPv4 address).
     - QCLASS: `0x0001` (Class IN — Internet).
3. **Response Parsing & Verification:**
   - Validates matching `ID` and `QR=1` (Response).
   - Validates `RCODE == 0` (No error; rejects `NXDOMAIN`, `SERVFAIL`, `REFUSED`).
   - Extracts the first valid 4-byte IPv4 address (`TYPE=1`, `CLASS=1`, `RDLENGTH=4`).
4. **Monitor & Runner Support:**
   - Monitor command: `net dns <hostname>` (prints `dns: <hostname> -> <ip>`).
   - Runner flag: `--net-dns-respond <resolver-ip>:<hostname>=<answer-ip>` in `PacketCapture.swift`.

---

### D3. Userland Network Applications & Proofs

Milestone twelve delivers three userland applications:

1. **`TCP.BIN` (`user/src/tcp_client.zig` — Issue #148):**
   - Direct EL0 TCP protocol proof.
   - Connects to `10.0.0.2:9999`, transmits a 5-byte payload, receives the echoed payload, closes cleanly, and exits 18.
2. **`FETCH.BIN` (`user/src/fetch.zig` — Issue #150):**
   - HTTP/1.0 GET client over TCP port 80.
   - Resolves hostnames via DNS (or takes IP), connects via `sys_tcp_connect`, sends `GET / HTTP/1.0\r\nHost: <host>\r\n\r\n`, streams the response payload, and exits with HTTP status code (200).
3. **`CHAT.BIN` (`user/src/chat.zig` — Issue #150):**
   - Peer-to-peer graphical chat application combining `user/src/lib/ui.zig` micro-widgets (`TextInput`, `ListView`, `Button`), `sys_win_open`, `sys_udp_listen`, and `sys_event_poll`.
   - Displays incoming messages in a scrolling list and sends typed messages to peer IP:port.

---

## Enforceability Table

| Requirement | Enforcing Gate |
|:---|:---|
| TCP syscall ABI slots 30–33 & `TCP.BIN` echo | Class B gate `tools/verify-live-net-tcp-syscall.sh` |
| RFC 1035 DNS client & monitor resolution | Class B gate `tools/verify-live-net-dns.sh` |
| `FETCH.BIN` HTTP/1.0 client retrieval over VZ | Class B Capstone gate `tools/verify-live-fetch.sh` |
| `CHAT.BIN` graphical peer-to-peer messaging | Class B Capstone verification |

---

## What this is not

- It is not a POSIX Berkeley sockets emulation layer (`socket()`, `bind()`, `select()`, `epoll()`).
- It is not TLS/HTTPS encryption (belongs to a dedicated security milestone).
- It is not a full web browser with HTML rendering or JavaScript execution.
- It does not modify existing frozen syscall slots (ADR 0007 slots 0–29).
