# Claim: Milestone 12 Card N3 — capstone applications FETCH.BIN & CHAT.BIN

- **Owner:** buffy (`agent/buffy/m12-n3-capstone-apps`)
- **Prompt / plan:** `docs/march-m12.md`
- **Scope:** Milestone 12, Card N3 (Issue #150: capstone applications FETCH.BIN & CHAT.BIN)
- **Depends on:** Milestone 12 Card N2 (`7566-n2-dns-client.md`), Issue #150
- **Status:** ✅ done

## Notes

Implements capstone userland network applications:
- `FETCH.BIN` (`user/src/fetch.zig`): Standalone EL0 HTTP/1.0 client over TCP (`sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close`). Formats HTTP GET requests, parses HTTP response status/headers/body, streams content to console, exits status 42.
- `CHAT.BIN` (`user/src/chat.zig`): Graphical peer-to-peer chat application combining Driving Award GUI windowing (`sys_win_open`, `sys_win_present`, `sys_poll_event`, `ui.zig`) with UDP networking (`sys_udp_listen`, `sys_udp_send`, `sys_udp_recv`).
- Desktop integration: added `FETCH.BIN` and `CHAT.BIN` to `DESKTOP.BIN` application launcher.
- Build & disk packaging: `build.zig`, `image/make-image.sh`, and `image/mkfat32.py`.
- VMRunner HTTP responder: HTTP GET response generation on TCP port 80 in `host/vm-runner/Sources/VMRunner/main.swift`.
- Class-B verification gate: `tools/verify-live-fetch.sh` observed PASS on real Apple Silicon Virtualization hardware:
  - `fetch: starting`
  - `fetch: connected`
  - `fetch: request sent`
  - `HTTP/1.0 200 OK`
  - `Hello from DipshitOS Host!`
  - `fetch: done`
  - `procs: id=1 name=FETCH.BIN state=exited task=reaped exit=42`
