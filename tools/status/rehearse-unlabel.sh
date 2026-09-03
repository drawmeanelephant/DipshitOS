#!/usr/bin/env bash
#
# rehearse-unlabel.sh -- end-to-end rehearsal of the REAL-TIME claim:stale
# removal path: the `unlabel-fresh` job in
# .github/workflows/claim-staleness.yml, which removes the `claim:stale`
# label the moment a stale-flagged claim issue gets human activity.
#
# What the rehearsal does:
#   1. creates a THROWAWAY claim issue (labeled `claim`),
#   2. marks it `claim:stale`,
#   3. produces human activity on it, and
#   4. verifies the label is removed, then cleans up (labels stripped, issue
#      closed with an "automated rehearsal" note). GitHub cannot delete
#      issues, so each run leaves exactly one closed "(rehearsal)" issue.
#
# Two modes:
#   cascade     -- real webhook delivery. A genuine issue_comment event fires
#                  the unlabel-fresh job — event delivery, the job's `if:`
#                  prefilter, tools/status/unlabel-guard.sh, and the job
#                  token's issues:write permission — and the script polls
#                  until claim:stale disappears. Requires a HUMAN-scoped
#                  actor: events created with the repository GITHUB_TOKEN do
#                  not spawn further workflow runs, and bot comments are
#                  (correctly) ignored by the guard. You get one by running
#                  locally as a collaborator (your gh login is the actor) or
#                  in CI with the repository secret CLAIM_REHEARSAL_TOKEN (a
#                  PAT with repo scope, owned by a write-access user).
#   guard-local -- the guard's LIVE branch is run in-process against the
#                  throwaway issue with a synthesized human payload. Proves
#                  the guard decision, real label removal, and token
#                  permissions in one job; event delivery and the job
#                  prefilter are not exercised. Used when the only credential
#                  is the bot token (CI without the secret), or forced with
#                  REHEARSAL_MODE=local.
#
# NOTE: the cascade fires the version of claim-staleness.yml on the DEFAULT
# branch of the repository — merge the workflow change first, or the event
# has no unlabel-fresh job to run.
#
# Usage:
#   rehearse-unlabel.sh                        # mode auto-detected
#   REHEARSAL_MODE=local rehearse-unlabel.sh   # force guard-local
#   REHEARSAL_TOKEN=<pat> rehearse-unlabel.sh  # force cascade with the PAT
#
# Env: GH_TOKEN (CI), REHEARSAL_TOKEN (optional PAT), REHEARSAL_MODE=local,
# REHEARSAL_TIMEOUT (default 180), REHEARSAL_INTERVAL (default 5).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

REHEARSAL_TOKEN="${REHEARSAL_TOKEN:-}"
TIMEOUT="${REHEARSAL_TIMEOUT:-180}"
INTERVAL="${REHEARSAL_INTERVAL:-5}"

[ "$TIMEOUT" -gt 0 ] 2>/dev/null || { echo "error: REHEARSAL_TIMEOUT must be a positive number" >&2; exit 2; }
[ "$INTERVAL" -gt 0 ] 2>/dev/null || { echo "error: REHEARSAL_INTERVAL must be a positive number" >&2; exit 2; }

command -v gh >/dev/null 2>&1 || { echo "error: 'gh' not found — install and authenticate the GitHub CLI" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not authenticated with GitHub — run 'gh auth login', or set GH_TOKEN (CI)" >&2; exit 1; }

# --- pick the mode -----------------------------------------------------------

MODE=""
if [ -n "$REHEARSAL_TOKEN" ]; then
    MODE="cascade"
    export GH_TOKEN="$REHEARSAL_TOKEN"
elif [ "${REHEARSAL_MODE:-}" = "local" ]; then
    MODE="guard-local"
else
    actor_login="$(gh api user --jq .login 2>/dev/null || echo "")"
    actor_type="$(gh api user --jq .type 2>/dev/null || echo "")"
    if [ -n "$actor_login" ] && [ "$actor_login" != "github-actions[bot]" ] && [ "$actor_type" = "User" ]; then
        MODE="cascade"
    else
        MODE="guard-local"
    fi
fi

echo "=== claim-staleness rehearsal ($MODE mode) ==="
if [ "$MODE" = "cascade" ]; then
    echo "posting a REAL human-scoped issue_comment — the unlabel-fresh job will fire against the throwaway issue"
    echo "note: the event runs the DEFAULT-branch version of claim-staleness.yml — merge this change first"
else
    echo "guard-local: running tools/status/unlabel-guard.sh in-process (event delivery not exercised;"
    echo "set the CLAIM_REHEARSAL_TOKEN secret or run locally as a collaborator for the full cascade)"
fi

num=""
payload=""
cleanup() {
    [ -n "$num" ] || return 0
    echo "cleanup: stripping labels and closing #$num"
    gh issue edit "$num" --remove-label claim --remove-label claim:stale >/dev/null 2>&1 || true
    gh issue close "$num" --comment "Claim-staleness rehearsal complete (automated)." >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- throwaway issue ----------------------------------------------------------

title="staleness rehearsal $(date -u +%Y%m%d-%H%M%S) (automated — safe to close)"
body="Automated rehearsal of the real-time \`claim:stale\` unlabel path. <!-- claim-rehearsal -->"
url="$(gh issue create --title "$title" --body "$body" --label claim)"
num="$(printf '%s\n' "$url" | sed -nE 's|.*/issues/([0-9]+).*|\1|p')"
[ -n "$num" ] || { echo "error: could not parse the created issue number from: $url" >&2; exit 1; }
echo "throwaway claim issue #$num: $url"
gh issue edit "$num" --add-label claim:stale >/dev/null
echo "marked #$num claim:stale"

if [ "$MODE" = "guard-local" ]; then
    # --- in-process guard run against the real issue -------------------------
    payload="$(mktemp)"
    cat > "$payload" <<EOF
{ "issue": { "number": $num, "state": "open",
    "labels": [ { "name": "claim" }, { "name": "claim:stale" } ] },
  "comment": { "user": { "login": "rehearsal", "type": "User" },
               "body": "rehearsal: simulated human progress update" },
  "sender": { "login": "rehearsal", "type": "User" } }
EOF
    echo "running the guard's live branch against #$num (synthesized human payload)..."
    out="$(GITHUB_EVENT_PATH="$payload" GITHUB_EVENT_NAME="issue_comment" bash tools/status/unlabel-guard.sh 2>&1)"
    printf '%s\n' "$out"
    if ! printf '%s' "$out" | grep -q "removed 'claim:stale' from claim #$num"; then
        echo "FAIL: the guard did not remove claim:stale from #$num" >&2
        exit 1
    fi
    if gh issue view "$num" --json labels --jq 'any(.labels[]; .name == "claim:stale")' 2>/dev/null | grep -qx true; then
        echo "FAIL: the guard reported success but claim:stale is still on #$num" >&2
        exit 1
    fi
    rm -f "$payload"
    echo "PASS: the guard's live branch removed claim:stale from #$num (real token permissions)"
    exit 0
fi

# --- cascade mode: real event, then poll -------------------------------------

gh issue comment "$num" --body "rehearsal: human progress update — unlabel-fresh should remove claim:stale from this throwaway issue" >/dev/null
echo "human comment posted — polling for label removal (timeout ${TIMEOUT}s, every ${INTERVAL}s)..."

ok=0
tries=0
max=$((TIMEOUT / INTERVAL))
while [ "$tries" -lt "$max" ]; do
    tries=$((tries + 1))
    if gh issue view "$num" --json labels --jq 'any(.labels[]; .name == "claim:stale")' 2>/dev/null | grep -qx false; then
        ok=1
        break
    fi
    sleep "$INTERVAL"
done

echo "recent claim-staleness runs (breadcrumb):"
gh run list --workflow claim-staleness.yml --limit 3 --json databaseId,event,conclusion \
    --jq '.[] | "  run #\(.databaseId) (\(.event)): \(.conclusion)"' 2>/dev/null || true

if [ "$ok" -eq 1 ]; then
    echo "PASS: claim:stale removed from #$num within ${TIMEOUT}s — the real event-driven path worked end to end"
    exit 0
fi
echo "FAIL: claim:stale still present on #$num after ${TIMEOUT}s — the event-driven job did not remove it" >&2
exit 1
