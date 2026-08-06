# Claim: M1.5 — host plumbing (agent A)

- **Owner:** buffy (`agent/buffy/m15-host-plumbing`)
- **Prompt / plan:** M1.5 steps 4–7 (`docs/m15-host-plumbing-prompt.md`)
- **Scope:** duplex serial attachment, live teeing, terminal safety, `zig build console`
- **Depends on:** —
- **Status:** ✅ 2026-08-06 — steps 4–7 landed

## Notes

`--console` mode in `host/vm-runner/Sources/VMRunner/main.swift` (stdin
input handle, streaming tee to terminal + log, termios restore on
exit/^C/SIGTERM/SIGHUP), `zig build console`, `just console`,
`tools/verify-host-console.sh`. **Observed:** host input plumbing proven
(`artifacts/m15-host-*.txt`); guest RX and the interactive prompt remain
unobserved. Log: `docs/logs/agent-buffy-m15-host-plumbing.md`.
