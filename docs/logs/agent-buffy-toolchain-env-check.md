# Log — agent/buffy/toolchain-env-check

- **2026-08-29** — *Buffy (agent/buffy/toolchain-env-check)*: claim
  9731 — host toolchain sanity check. Added `tools/env-check.sh` (sourceable
  one-shot that re-prepends the Homebrew bin dir and verifies the modern
  builds of bash/sed/jq/yq ahead of the macOS system versions, printing a
  loud red complaint and returning non-zero when they are not), a
  `just check-env` recipe, and an AGENTS.md "Host toolchain sanity check
  (source me first)" section so every session checks once. Verified on the
  real dev host: default PATH flags `/bin/bash` 3.2.57 + BSD `/usr/bin/sed`
  (rc=1); Homebrew-first PATH passes bash 5.3.15 + jq 1.8.2, still flagging
  GNU sed because `gnu-sed` is not installed. Tooling-only — no guest code,
  no milestone work. Status: 🔄.