#!/usr/bin/env bash
#
# new-claim.sh -- file a claim as a GitHub issue (label `claim`).
#
# Claims no longer live in repo files (the docs/claims/ + docs/logs/ file
# system was deleted 2026-09-03). A claim is ONE GitHub issue on the project
# tracker: OPEN = in progress, progress notes are issue comments, close the
# issue (with an evidence comment) when the work lands. The coordination
# gate (tools/status/verify-issue-coordination.sh) reads open claim issues:
# two open claims from different branches whose Touches overlap fail the
# gate, so declare every file you will edit.
#
# Usage:
#   bash tools/status/new-claim.sh --title "Fix the boot probe flake (#810)" \
#       [--owner buffy] [--branch agent/buffy/foo] \
#       [--scope "M34 follow-up: root-cause + fix ..."] \
#       [--touches "kernel/src/exceptions.zig, kernel/src/scheduler.zig"] \
#       [--depends "#810"] [--verification "verify-live-vf.sh 6/6 on VZ"] \
#       [--notes "..." --dry-run]
#
# Defaults: --branch = the current git branch; --owner = the agent name
# derived from `agent/<name>/<slug>` branches (else git user.name). The
# created issue is printed (--dry-run prints the body instead of creating).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TITLE="" OWNER="" BRANCH="" SCOPE="" TOUCHES="" DEPENDS="—" VERIFICATION="" NOTES=""
DRY_RUN=0

usage() {
    sed -n 's/^#   //p' "$0" | sed -n '/^Usage:/,/^Defaults:/p'
    exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --title) TITLE="${2:-}"; shift 2 ;;
        --owner) OWNER="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --scope) SCOPE="${2:-}"; shift 2 ;;
        --touches) TOUCHES="${2:-}"; shift 2 ;;
        --depends) DEPENDS="${2:-}"; shift 2 ;;
        --verification) VERIFICATION="${2:-}"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "new-claim.sh: unknown argument: $1" >&2; usage 2 ;;
    esac
done

[ -n "$TITLE" ] || { echo "new-claim.sh: --title is required" >&2; usage 2; }

if [ -z "$BRANCH" ]; then
    BRANCH="$(git branch --show-current 2>/dev/null || true)"
    [ -n "$BRANCH" ] || BRANCH="<branch>"
fi

if [ -z "$OWNER" ]; then
    case "$BRANCH" in
        agent/*) OWNER="$(printf '%s\n' "$BRANCH" | cut -d/ -f2)" ;;
        *) OWNER="$(git config user.name 2>/dev/null || echo agent)" ;;
    esac
fi

if [ -n "$TOUCHES" ]; then
    # Keep the field machine-parseable: one line, comma separated.
    TOUCHES="$(printf '%s\n' "$TOUCHES" | tr -s ' ' | tr ' ' ',')"
fi

[ -n "$SCOPE" ] || SCOPE="—"
[ -n "$TOUCHES" ] || TOUCHES="—"
[ -n "$VERIFICATION" ] || VERIFICATION="—"
[ -n "$NOTES" ] || NOTES="<what this claim is, why it matters, how it will be verified>"

body="$(cat <<EOF
## Claim

- **Owner:** $OWNER (\`$BRANCH\`)
- **Scope:** $SCOPE
- **Touches:** $TOUCHES
- **Depends on:** $DEPENDS
- **Verification:** $VERIFICATION
- **Status:** 🔄

## Notes

$NOTES

---
Progress lives in COMMENTS on this issue (append a new comment; never
rewrite earlier ones). Close the issue with a final evidence comment when
the work lands or is abandoned. Filed by tools/status/new-claim.sh — the
coordination gate treats this open \`claim\` issue as ACTIVE.
EOF
)"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$body"
    exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "new-claim.sh: 'gh' not found — install and authenticate the GitHub CLI" >&2; exit 1; }

url="$(gh issue create --label claim --title "claim: $TITLE" --body "$body")"
echo "filed claim issue: $url"
