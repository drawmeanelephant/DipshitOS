# Log — Milestone 12 Card N3: capstone applications FETCH.BIN & CHAT.BIN

- **Branch:** `agent/buffy/m12-n3-capstone-apps`
- **Claim:** [`docs/claims/5416-n3-capstone-apps.md`](../claims/5416-n3-capstone-apps.md)
- **Scope:** Milestone 12 Card N3 (Issue #150: capstone applications FETCH.BIN & CHAT.BIN)

## Entries

- **2026-08-15:** Started Card N3. Created branch `agent/buffy/m12-n3-capstone-apps` and filed claim 5416.
- **2026-08-15:** Completed Card N3 (Issue #150: capstone applications FETCH.BIN & CHAT.BIN).
  - Implemented standalone HTTP/1.0 client `FETCH.BIN` (`user/src/fetch.zig`) establishing TCP connection from EL0 via `sys_tcp_connect`, issuing GET request via `sys_tcp_send`, streaming response via `sys_tcp_recv`, closing connection with `sys_tcp_close`, and cleanly exiting 42.
  - Implemented graphical peer-to-peer chat application `CHAT.BIN` (`user/src/chat.zig`) pairing Driving Award GUI windowing (`sys_win_open`, `sys_win_present`, `sys_poll_event`, `ui.zig`) with UDP datagram networking (`sys_udp_listen`, `sys_udp_send`, `sys_udp_recv`).
  - Added userland networking wrappers and constants to `user/src/lib/ui.zig`.
  - Added `FETCH.BIN` and `CHAT.BIN` to desktop launcher entries in `user/src/desktop.zig`.
  - Updated `build.zig`, `image/make-image.sh`, and `image/mkfat32.py` to compile and package both binaries onto FAT32 root.
  - Updated host VMRunner TCP responder in `host/vm-runner/Sources/VMRunner/main.swift` to serve HTTP/1.0 200 OK responses on port 80.
  - Created Class-B live test `tools/verify-live-fetch.sh` and observed PASS on Apple Silicon VZ hardware.
  - Verified unit test suite (`verify-unit-tests.sh` passes all 35 modules) and live TCP/DNS tests.
