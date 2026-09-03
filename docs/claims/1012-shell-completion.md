# Claim: Shell completion — tab-complete commands + args

- **Owner:** antigravity (`agent/antigravity/783-shell-completion`)
- **Prompt / plan:** issue #783 (re-filed from #711, umbrella #620)
- **Scope:** Self-hosting #20 — Shell completion: tab-complete commands + args
- **Touches:** kernel/src/shell.zig kernel/src/lineedit.zig tools/verify-live-scripting.sh docs/claims/1012-shell-completion.md docs/logs/agent-antigravity-783-shell-completion.md
- **Depends on:** —
- **Heartbeat:** 2026-09-03
- **Status:** 🔄 agent/antigravity/783-shell-completion

## Notes

Takes issue #783: Shell completion beyond M18/M19.
- Command-name completion from the shell's verb table + action registry.
- Argument completion for verbs that declare candidates (app names, `exec *.ELF`, file paths).
- Tab cycling through candidates.
- Class-A unit tests in `kernel/src/lineedit.zig` / `kernel/src/shell.zig`.
- Class-B live verification phase in `tools/verify-live-scripting.sh`.
