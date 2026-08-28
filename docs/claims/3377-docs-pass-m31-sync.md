# Claim: docs pass — sync README, AGENTS, status, and the GitHub Pages site to the M31 world

- **Owner:** buffy (`agent/buffy/docs-pass`)
- **Prompt / plan:** user-directed overall documentation pass (README, GitHub Pages corpus, milestone status) after pulling the latest `main`
- **Scope:** documentation-only; no kernel/userland/host code changes. Bring the public and coordination docs up to the post-M31 reality: every milestone through M31 closed, zero open issues, no M32 defined.
- **Touches:** README.md, AGENTS.md, docs/status.md, site/index.md, site/roadmap.md, site/architecture.md, site/capabilities.md, site/networking.md, site/memory.md, site/processes.md, site/userspace.md, site/programs.md, site/run.md, site/live-gates.md, site/build.md, site/drivers.md, docs/logs/agent-buffy-docs-pass.md
- **Depends on:** — (branch cut from `origin/main` `da695dd`)
- **Heartbeat:** 2026-08-28
- **Status:** ✅ done

## Notes

The local checkout was on `agent/buffy/input-poll-563`, which PR #593 had
already merged; `origin/main` had advanced to M28–M31, `HTTPD.BIN`, the M26
preflight cards, and the `sys_tcp_connect` fix. This claim re-based the docs
work on a fresh branch off `origin/main` and closed the staleness gap:

- **README.md / AGENTS.md** stopped at milestone 13/14 → rewritten to the
  M0–M31 summary, zero-open-issues state, and the "no M32 yet" note.
- **docs/status.md** gained M17–M31 rows in the Current position table
  (with GitHub-milestone/issue/claim citations), a rewritten "What comes
  next" (everything closed, ABI effectively full at 65/128 implemented),
  and removed the stale open-thread caveats (#151/#179 both closed).
- **site/** (the GitHub Pages corpus) stopped at milestone 16 → index,
  roadmap, architecture, capabilities, networking, memory, processes,
  userspace, programs, run, live-gates, build, and drivers pages updated:
  SMP (M28), VM depth (M29), dynamic linking (M30/M31), the `HTTPD.BIN`
  TCP server, 65-of-128 syscall slots, the 11-slot scheduler pool, 136 live
  gate scripts, 69 monitor commands, and the 47-program + dynamic-ELF
  inventory.

Verification: facts cross-checked against the GitHub API (milestones,
issues, PRs), the kernel source (`syscall.zig` slot map,
`scheduler.zig max_tasks`, `file_table.zig`), the build manifest
(`build.zig` program list), and the march trackers. No class-A/B gates are
affected (docs-only); `zig build context` regenerates the snapshot.
