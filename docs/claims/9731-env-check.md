# Claim: host toolchain sanity check (env-check)

- **Owner:** Buffy (`agent/buffy/toolchain-env-check`)
- **Prompt / plan:** startup tooling request — give every agent a sourceable
  one-shot check that verifies the MODERN Homebrew builds of the Unix
  toolchain (bash/sed/jq/yq) are ahead of the macOS system builds on PATH,
  and bitches loudly when they are not.
- **Scope:** dev tooling only — a sourceable `tools/env-check.sh`, a
  `just check-env` recipe, and an AGENTS.md "source me first" pointer. No
  guest code, no kernel, no mounts, no milestone work.
- **Touches:** tools/env-check.sh, justfile, AGENTS.md, docs/claims/9731-env-check.md, docs/logs/agent-buffy-toolchain-env-check.md
- **Depends on:** —
- **Heartbeat:** 2026-08-29
- **Status:** 🔄 agent/buffy/toolchain-env-check

## Notes

Non-interactive agents frequently spawn with PATH putting `/usr/bin` and
`/bin` ahead of `/opt/homebrew/bin`, so `bash` and `sed` silently resolve
to the 2007-era `/bin/bash` 3.2 and the BSD `/usr/bin/sed`, and the build +
gate scripts misbehave in confusing ways. The existing gate scripts already
harden the known-sensitive calls by prefixing
`PATH="/opt/homebrew/bin:..."` (e.g. `verify-live-n5-dns.sh`), but nothing
signaled *startup*, and nothing explained the failure mode.

`tools/env-check.sh` closes that gap:
- Re-prepends the Homebrew bin dir (Apple silicon `/opt/homebrew/bin`,
  Intel `/usr/local/bin`, or `$BREW_PREFIX`) to PATH without clobbering the
  rest.
- Resolves `bash`/`sed`/`jq`/`yq` via `command -v` and verifies the modern
  build: bash 3.2 under `/bin` → fail; BSD sed (GNU `--version` absent, and
  `/bin` or `/usr/bin` path) → fail; jq `< 1.6` version-aware → fail.
- Prints a loud red `YOU ARE ABOUT TO RUN THE WRONG TOOLS…` banner naming
  each offender and the fix, and returns non-zero when anything is wrong.
- Idempotent + source-safe: direct exec exits with the verdict; sourcing
  runs the check but does not kill the interactive shell.

Verified on the dev host: the real machine PATH (with `/bin`/`/usr/bin`
leading) correctly flags `/bin/bash` 3.2.57 and BSD `/usr/bin/sed` and
returns 1; with `PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"`
the same check passes Homebrew bash 5.3.15 and jq 1.8.2, and only continues
to flag GNU sed because `gnu-sed` is not installed on this host (the fix
hint names it). `just check-env` returns the check's status.

**Verified when:** `bash tools/verify-coordination.sh` PASS; `zig fmt
--check` + `just build` untouched by this claim (tooling-only); the three
files above land on `main` with `docs/status.md` unchanged.