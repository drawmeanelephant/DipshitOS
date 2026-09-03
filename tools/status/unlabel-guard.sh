#!/usr/bin/env bash
#
# unlabel-guard.sh -- real-time `claim:stale` removal guard (shared logic).
#
# The `unlabel-fresh` job in .github/workflows/claim-staleness.yml removes
# the `claim:stale` label the moment a stale-flagged claim issue sees HUMAN
# activity, so the stale filter is accurate in real time. The bot-vs-human
# decision used to be inline Actions shell inside the workflow; it lives HERE
# so it is one executable artifact, exercised OFFLINE against fixture webhook
# payloads by tools/status/test-coordination.sh (the unlabel-guard cases)
# before this job ever fires in production.
#
# Decision (mirrors the job's cheap `if:` prefilter, then the human check):
#   * prefilter — the event must be issue_comment or issues, the issue must
#     be OPEN and carry the `claim:stale` label; otherwise nothing to do.
#   * issue_comment — the comment author must be a human: not
#     github-actions[bot], not user.type == 'Bot', and the body must not
#     carry the sweep's marker (a LOCAL-token sweep run comments as its
#     owner, a plain 'User', so the marker — not the author — is what
#     identifies that comment).
#   * issues (edited/reopened/transferred) — the sender must be a human.
#
# Anything bot-authored is skipped with a reason; only genuine human
# activity clears the label, so the sweep can never unlabel itself.
#
# Usage:
#   unlabel-guard.sh                # live: reads $GITHUB_EVENT_PATH +
#                                   #       $GITHUB_EVENT_NAME, removes the label
#   unlabel-guard.sh --payload <webhook.json> [--event issue_comment|issues]
#                                   # offline: prints the decision, never writes
#
# The fixture is a GitHub webhook payload in the shape of the issue_comment
# / issues events (see webhook_event() in tools/status/test-coordination.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STALE_LABEL="claim:stale"
MARKER="claim-staleness-bot"

PAYLOAD=""
EVENT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --payload)
            PAYLOAD="${2:-}"
            [ -n "$PAYLOAD" ] || { echo "usage: --payload <file>" >&2; exit 2; }
            shift 2 ;;
        --event)
            EVENT="${2:-}"
            [ -n "$EVENT" ] || { echo "usage: --event <name>" >&2; exit 2; }
            shift 2 ;;
        *)
            echo "usage: unlabel-guard.sh [--payload <webhook.json> [--event issue_comment|issues]]" >&2
            exit 2 ;;
    esac
done

LIVE=0
if [ -z "$PAYLOAD" ]; then
    LIVE=1
    PAYLOAD="${GITHUB_EVENT_PATH:-}"
    EVENT="${GITHUB_EVENT_NAME:-}"
    [ -n "$PAYLOAD" ] || { echo "error: no payload — pass --payload <file>, or run inside a GitHub Actions job (\$GITHUB_EVENT_PATH)" >&2; exit 2; }
    [ -n "$EVENT" ] || { echo "error: no event name — pass --event, or run inside a GitHub Actions job (\$GITHUB_EVENT_NAME)" >&2; exit 2; }
fi
[ -f "$PAYLOAD" ] || { echo "error: payload file not found: $PAYLOAD" >&2; exit 2; }

case "$EVENT" in
    issue_comment|issues) ;;
    *)
        echo "error: unsupported event '$EVENT' (expected issue_comment or issues)" >&2
        exit 2 ;;
esac

num="$(jq -r '.issue.number // empty' "$PAYLOAD")"
[ -n "$num" ] || { echo "skip: payload has no issue — nothing to do"; exit 0; }

# --- prefilter (the job-level `if:` dispatch, re-checked so this script is
# --- safe to run standalone) ------------------------------------------------

state="$(jq -r '.issue.state // ""' "$PAYLOAD")"
if [ "$state" != "open" ]; then
    echo "skip: issue #$num is '$state', not open — nothing to unlabel"
    exit 0
fi
if ! jq -e --arg n "$STALE_LABEL" '(.issue.labels // []) | any(.[]; .name == $n)' "$PAYLOAD" >/dev/null 2>&1; then
    echo "skip: issue #$num does not carry the '$STALE_LABEL' label — nothing to unlabel"
    exit 0
fi

# --- bot-vs-human check ------------------------------------------------------

if [ "$EVENT" = "issue_comment" ]; then
    author="$(jq -r '.comment.user.login // ""' "$PAYLOAD")"
    atype="$(jq -r '.comment.user.type // "User"' "$PAYLOAD")"
    body="$(jq -r '.comment.body // ""' "$PAYLOAD")"
    if [ "$author" = "github-actions[bot]" ] || [ "$atype" = "Bot" ]; then
        echo "skip: comment on #$num is from bot '$author' — not human activity; keeping the label"
        exit 0
    fi
    if printf '%s' "$body" | grep -q "$MARKER"; then
        echo "skip: comment on #$num is the sweep's own warning (marker present) — not human activity; keeping the label"
        exit 0
    fi
else
    sender="$(jq -r '.sender.login // ""' "$PAYLOAD")"
    stype="$(jq -r '.sender.type // "User"' "$PAYLOAD")"
    if [ "$sender" = "github-actions[bot]" ] || [ "$stype" = "Bot" ]; then
        echo "skip: bot-driven issue event on #$num ($sender) — not human activity; keeping the label"
        exit 0
    fi
fi

echo "unlabel: human activity on stale-flagged claim #$num — removing the '$STALE_LABEL' label"
[ "$LIVE" -eq 1 ] || exit 0

# --- live mode only: act -----------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'gh' not found — required for live label removal (GH_TOKEN in CI)" >&2
    exit 1
fi
if gh issue edit "$num" --remove-label "$STALE_LABEL" >/dev/null; then
    echo "removed '$STALE_LABEL' from claim #$num"
else
    echo "::warning::could not remove claim:stale from #$num (already gone, or the token lacks permission for this actor)"
fi
