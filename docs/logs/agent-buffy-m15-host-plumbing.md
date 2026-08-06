# Log — `agent/buffy/m15-host-plumbing` (PR #13)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy, `agent/buffy/m15-host-plumbing`):**
  claimed the M1.5 host-plumbing row (agent A, steps 4–7) per AGENTS.md.
  Branch created from updated `main` (post bad-handoff fix, `05ee69d`).
  Plan: `--console` mode in `host/vm-runner/Sources/VMRunner/main.swift`
  (duplex attachment with stdin input handle, streaming tee of guest output
  to terminal + `vm-serial.log`, termios raw/character input with restore on
  exit/signals), `zig build console` + `just console`, honest diagnostics.
  No kernel files touched; `zig build run` evidence semantics unchanged.
  🔄 in progress — implementation and gates to follow.
- **2026-08-06** — **M1.5 host plumbing landed (buffy,
  `agent/buffy/m15-host-plumbing`):** steps 4–7 done, host-side only; no
  kernel files touched. `host/vm-runner/Sources/VMRunner/main.swift` gained
  `--console` (duplex `VZFileHandleSerialPortAttachment` with a stdin pipe
  as `fileHandleForReading`, streaming tee of guest output to the terminal +
  `vm-serial.log`, termios character mode restored on exit/^C/SIGTERM/
  SIGHUP/failure via atexit + dispatch signal sources, `--debug-input` byte
  evidence on stderr, honest diagnostics); `build.zig` gained
  `zig build console`; `justfile` gained `console` and `verify-host-console`;
  new gate `tools/verify-host-console.sh`. **Observed:** scripted piped run
  forwarded `hello\r` to the serial attachment as `68 65 6c 6c 6f 0d` and
  ended cleanly by timeout; PTY run caught SIGINT and exited 130 with the
  pty termios restored to ICANON+ECHO; `zig build console` booted with full
  diagnostics and restored the terminal on SIGTERM; `zig build run`
  unchanged (serial gate still blocked, `vm-serial.log` 0 bytes). Host
  **input plumbing observed**; guest RX and the interactive monitor prompt
  remain **unobserved** (guest RX is agent B's slice; the VZ serial gate is
  still blocked). Evidence: `artifacts/m15-host-*.txt`. ✅
- **2026-08-06** — **CI unit-test gate (buffy, `agent/buffy/m15-host-plumbing`):**
  CI now format-checks `boot/src/*.zig kernel/src/*.zig build.zig` and runs
  the M1.5 kernel monitor module unit tests via
  `tools/verify-unit-tests.sh` — `zig test` on each module present in
  `kernel/src/` (console/handoff/memmap/monitor). Modules that have not
  landed yet (agent C's commands slice) are skipped with a notice so `main`
  stays green; once each module merges, its tests become binding
  branch-protection evidence instead of local-only claims. `just test`
  added; `just verify` and `docs/testing.md` updated to match. ✅
