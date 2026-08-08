#!/usr/bin/env bash
#
# claim-id.sh -- print the deterministic claim ID for a new claim.
#
# The old "next sequential number" convention collided when two agents
# claimed concurrently: claim 0013 was claimed by serial-discovery at 10:27
# and by status-reverify at 15:18, and the loser had to be manually
# renumbered to 0014 (commit be811cb). Claim IDs are now a pure function of
# (branch, slug), so two agents claiming different work cannot pick the same
# number, no shared file is edited to claim, and the result is reproducible
# on any machine:
#
#     NNNN = 0024 + (cksum("<branch>:<slug>") % 9976)
#
# mapped into [0024, 9999] so derived IDs never overlap the grandfathered
# sequential range 0001-0023. verify-coordination.sh recomputes the ID from
# each claim file (owner branch + filename slug) and fails on mismatch for
# claims numbered 0024+, so a hand-picked "next" number cannot slip through.
#
# cksum is POSIX (present on macOS and Linux alike) and deterministic across
# platforms, so the ID is stable everywhere.
#
# Usage:
#   claim-id.sh <branch> <slug>     # print the zero-padded 4-digit ID
#
# Example:
#   $ bash tools/status/claim-id.sh 'agent/buffy/m15-foo' 'fix-the-thing'
#   1801

set -euo pipefail

branch="${1:-}"
slug="${2:-}"

if [ -z "$branch" ]; then
    echo "usage: claim-id.sh <branch> <slug>" >&2
    exit 2
fi

case "$slug" in
    ""|*[!a-z0-9-]*)
        echo "claim-id.sh: slug must be kebab-case ([a-z0-9-]): '$slug'" >&2
        exit 2 ;;
esac

sum="$(printf '%s:%s' "$branch" "$slug" | cksum | awk '{print $1}')"
printf '%04d\n' $((24 + sum % 9976))
