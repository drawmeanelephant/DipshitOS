# Claim: In-Guest HTTP/1.1 Web Server (HTTPD.BIN)

- **Owner:** Buffy (`agent/buffy/input-poll-563`)
- **Heartbeat:** 2026-08-27
- **Prompt / plan:** `docs/roadmap.md`, `implementation_plan.md`
- **Scope:** In-guest HTTP/1.1 daemon (`HTTPD.BIN`), TCP passive open / listen mode in `kernel/src/tcp.zig`, static file serving from FAT32, `/api/status` JSON telemetry, and live verification gate `tools/verify-live-httpd.sh`.
- **Depends on:** M0–M27 done ✅
- **Touches:** `kernel/src/tcp.zig`, `kernel/src/syscall.zig`, `kernel/src/monitor.zig`, `kernel/src/esp.zig`, `user/src/lib/ui.zig`, `user/src/httpd.zig`, `build.zig`, `image/apps.txt`, `image/make-image.sh`, `image/mkfat32.py`, `tools/verify-live-httpd.sh`
- **Status:** ✅ done 2026-08-27 — verified live on Apple Silicon VZ (tools/verify-live-httpd.sh)

## Notes

- Passive open (listen mode) in `kernel/src/tcp.zig` reuses existing slots 30–33 with IP=0.
- Zero new syscall slots, zero heap in kernel, bounded BSS.
- Static file serving directly reads FAT32 via userland file syscalls.
- Class-B hardware gate `verify-live-httpd.sh` tests real HTTP request/response lifecycles.
