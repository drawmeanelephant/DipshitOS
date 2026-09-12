#!/usr/bin/env bash
#
# claim-card.sh -- claim an EXISTING GitHub issue (a milestone card) in place.
#
# One issue per card, and the card IS the claim: run this instead of filing a
# second `claim` issue. It adds the `claim` label and writes the machine-read
# fields the coordination gate parses (tools/status/verify-issue-coordination.sh):
# an `Owner` bullet naming the agent and its backticked branch, a comma-separated
# `Touches` bullet, and an optional `Status: ⛔`. Existing fields are updated in
# place; a card with none gets a `## Claim` block prepended.
#
# Usage:
#   bash tools/status/claim-card.sh <issue> \
#       [--owner <name>] [--branch <branch>] \
#       [--scope "..."] [--touches "a.zig, b.zig"] \
#       [--depends "#n"] [--verification "..."] [--notes "..."] [--dry-run]
#
# Defaults: --branch = the current git branch; --owner = the agent name derived
# from `agent/<name>/<slug>` (else git user.name). The landing PR MUST say
# `Closes #<issue>` so merge closes the claim.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ISSUE="" OWNER="" BRANCH="" SCOPE="" TOUCHES="" DEPENDS="—" VERIFICATION="" NOTES=""
DRY_RUN=0

usage() {
    sed -n 's/^#   //p' "$0" | sed -n '/^Usage:/,/^Defaults:/p'
    exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --owner) OWNER="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --scope) SCOPE="${2:-}"; shift 2 ;;
        --touches) TOUCHES="${2:-}"; shift 2 ;;
        --depends) DEPENDS="${2:-}"; shift 2 ;;
        --verification) VERIFICATION="${2:-}"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "claim-card.sh: unknown argument: $1" >&2; usage 2 ;;
        *) if [ -z "$ISSUE" ]; then ISSUE="$1"; shift; else echo "claim-card.sh: unexpected argument: $1" >&2; usage 2; fi ;;
    esac
done

[ -n "$ISSUE" ] || { echo "claim-card.sh: <issue> is required" >&2; usage 2; }
case "$ISSUE" in *[!0-9]*) echo "claim-card.sh: <issue> must be a number, got '$ISSUE'" >&2; exit 2 ;; esac

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
    TOUCHES="$(printf '%s\n' "$TOUCHES" | tr ',' ' ' | tr -s ' ' | tr ' ' ',')"
fi
[ -n "$SCOPE" ] || SCOPE="—"
[ -n "$TOUCHES" ] || TOUCHES="—"
[ -n "$VERIFICATION" ] || VERIFICATION="—"

command -v gh >/dev/null 2>&1 || { echo "claim-card.sh: 'gh' not found — install and authenticate the GitHub CLI" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "claim-card.sh: 'python3' not found (project toolchain dependency)" >&2; exit 1; }

old_body="$(gh issue view "$ISSUE" --json body -q .body)"

new_body="$(
    OLD_BODY="$old_body" \
    OWNER="$OWNER" BRANCH="$BRANCH" SCOPE="$SCOPE" TOUCHES="$TOUCHES" \
    DEPENDS="$DEPENDS" VERIFICATION="$VERIFICATION" NOTES="$NOTES" \
    python3 - <<'PY'
import os, re, sys

fields = [
    ("Owner", os.environ["OWNER"] + " (`" + os.environ["BRANCH"] + "`)"),
    ("Scope", os.environ["SCOPE"]),
    ("Touches", os.environ["TOUCHES"]),
    ("Depends on", os.environ["DEPENDS"]),
    ("Verification", os.environ["VERIFICATION"]),
    ("Status", "\U0001F504"),
]
body = os.environ["OLD_BODY"]
had_owner = re.search(r"^- \*\*Owner:\*\*", body, re.M) is not None

def set_field(text, name, value):
    pat = re.compile(r"^- \*\*" + re.escape(name) + r":\*\*[^\n]*$", re.M)
    line = "- **" + name + ":** " + value
    if pat.search(text):
        return pat.sub(lambda m: line, text, count=1)
    return text

for name, value in fields:
    body = set_field(body, name, value)

if not had_owner:
    block = "## Claim\n\n" + "\n".join("- **%s:** %s" % (n, v) for n, v in fields) + "\n\n"
    if os.environ.get("NOTES"):
        block += "## Notes\n\n" + os.environ["NOTES"] + "\n\n"
    body = block + "---\n\n" + body

sys.stdout.write(body)
PY
)"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$new_body"
    exit 0
fi

gh issue edit "$ISSUE" --add-label claim --body "$new_body" >/dev/null
echo "claimed card #$ISSUE (label claim; Owner=$OWNER branch=$BRANCH)"
echo "landing PR must contain:  Closes #$ISSUE"
