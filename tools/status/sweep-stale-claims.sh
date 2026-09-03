#!/usr/bin/env bash
#
# sweep-stale-claims.sh -- weekly staleness sweep for claim issues.
#
# Claims are GitHub issues labeled `claim` (AGENTS.md coordination rules):
# an OPEN claim is ACTIVE work, and any comment or edit keeps it alive. A
# claim with no update for STALE_DAYS (default 14) is stale.
#
# What this sweep does, once a week (and manually via workflow_dispatch):
#   * Warn + label: every stale open claim that is not yet flagged gets a
#     warning comment and the `claim:stale` label, so stale claims are
#     filterable (`gh issue list --label claim --label claim:stale`).
#   * Unlabel: a claim carrying `claim:stale` that has had fresh HUMAN
#     activity (comment or edit after the warning) has the label removed —
#     the tracker stays an honest filter of currently-stale claims. The
#     event-driven unlabel job in .github/workflows/claim-staleness.yml
#     does this in real time on every comment/edit/reopen; this sweep's
#     unlabel pass is the weekly catch-up for anything the events missed.
#
# Staleness is bot-aware. Labeling/commenting refreshes the issue's
# updated_at, which would otherwise reset the clock: when the issue's most
# recent comment is this sweep's own warning, idle time counts from that
# warning's timestamp instead of updated_at, so a flagged claim only stops
# being stale when a human updates it.
#
# Usage:
#   sweep-stale-claims.sh                # live: comment + label / unlabel
#   sweep-stale-claims.sh --dry-run      # live: print intended actions only
#   sweep-stale-claims.sh --issues-json <file>   # offline fixture (prints only)
#
# The fixture is the JSON shape of `gh issue list --json
# number,title,url,body,updatedAt,labels` (used by
# tools/status/test-coordination.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ISSUES_JSON=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --issues-json)
            ISSUES_JSON="${2:-}"
            [ -n "$ISSUES_JSON" ] || { echo "usage: --issues-json <file>" >&2; exit 2; }
            shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *)
            echo "usage: sweep-stale-claims.sh [--dry-run] [--issues-json <file>]" >&2
            exit 2 ;;
    esac
done

STALE_DAYS="${STALE_DAYS:-14}"
STALE_LABEL="claim:stale"
MARKER="claim-staleness-bot"
# If a human acts within this window after a warning, treat it as the bot
# bump, not fresh activity (label/comment updates land within seconds).
BUMP_EPSILON=300

# --- fetch open claim issues -----------------------------------------------

if [ -n "$ISSUES_JSON" ]; then
    json="$(cat "$ISSUES_JSON")"
else
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: 'gh' not found — install and authenticate the GitHub CLI (or pass --issues-json <file> for offline checks)" >&2
        exit 1
    fi
    json="$(gh issue list --label claim --state open --limit 200 \
        --json number,title,url,body,updatedAt,labels 2>/dev/null)" \
        || { echo "error: 'gh issue list' failed — are you authenticated and inside the repository? (GH_TOKEN in CI)" >&2; exit 1; }
fi

now="$(date -u +%s)"

# iso_epoch ISO8601 -- gh's updatedAt -> unix epoch (see the gate for notes).
iso_epoch() {
    python3 -c '
import sys, datetime
s = sys.argv[1].split(".")[0].rstrip("Z")
print(int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").timestamp()))
' "$1"
}

# has_label JSON_LABELS NAME -- does the issue carry NAME?
has_label() {
    printf '%s\n' "$1" | jq -e --arg n "$2" 'any(.[]; .name == $n)' >/dev/null 2>&1
}

# last_comment NUM -> prints "<created_at>\t<body>" of the most recent
# comment (or nothing). Live mode only.
last_comment() {
    gh api "issues/$1/comments?per_page=1" \
        --jq '.[0] | [.created_at, (.body // "")] | @tsv' 2>/dev/null || true
}

# --- decision helpers -------------------------------------------------------
#
# idle_ts UPDATED_AT MARKER_TS -- the timestamp real staleness counts from:
# the issue's updated_at, unless the only recent activity is a bot warning
# (then the warning's timestamp — labeling/commenting must not reset the
# clock). MARKER_TS is the created_at of the last comment when it is one of
# our warnings, else empty.

stale=0
labeled=0
unlabeled=0
already_flagged=0
checked=0

while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    num="$(jq -r '.number' <<<"$rec")"
    title="$(jq -r '.title' <<<"$rec")"
    url="$(jq -r '.url' <<<"$rec")"
    upd="$(jq -r '.updatedAt' <<<"$rec")"
    labels="$(jq -c '.labels // []' <<<"$rec")"
    checked=$((checked + 1))

    upd_ts="$(iso_epoch "$upd")" || upd_ts=""
    [ -n "$upd_ts" ] || continue
    age=$(( (now - upd_ts) / 86400 ))

    # Which claims need the last-comment lookup? Only ones this sweep could
    # act on: already flagged (unlabel decision) or old enough to flag.
    marker_ts=""
    if has_label "$labels" "$STALE_LABEL" || [ "$age" -ge "$STALE_DAYS" ]; then
        lc="$(last_comment "$num")"
        if [ -n "$lc" ]; then
            lc_ts="$(printf '%s\n' "$lc" | cut -f1)"
            lc_body="$(printf '%s\n' "$lc" | cut -f2-)"
            if printf '%s' "$lc_body" | grep -q "$MARKER"; then
                marker_ts="$(iso_epoch "$lc_ts")" || marker_ts=""
            fi
        fi
    fi

    # Real idle time: if the last activity is our own warning, the claim has
    # been idle since that warning; otherwise updated_at is the truth.
    if [ -n "$marker_ts" ] && [ $((upd_ts - marker_ts)) -le "$BUMP_EPSILON" ]; then
        idle_ts="$marker_ts"
    else
        idle_ts="$upd_ts"
    fi
    idle_age=$(( (now - idle_ts) / 86400 ))

    if [ "$idle_age" -ge "$STALE_DAYS" ]; then
        # Stale. Flag once per stale period (label present = already flagged).
        if has_label "$labels" "$STALE_LABEL"; then
            already_flagged=$((already_flagged + 1))
            printf 'skip claim #%s (%s): stale but already flagged\n' "$num" "$title"
            continue
        fi
        stale=$((stale + 1))
        if [ -n "$ISSUES_JSON" ] || [ "$DRY_RUN" -eq 1 ]; then
            printf 'warn+label claim #%s (%s): no update for %d days\n' "$num" "$title" "$idle_age"
            labeled=$((labeled + 1))
            continue
        fi
        body="**Automated staleness check** — this \`claim\` issue has had no update for **$idle_age days** (threshold: $STALE_DAYS). Any comment or edit keeps a claim alive (AGENTS.md coordination rules): post a progress update, or close the issue if the work is done or abandoned. Past ~21 days, anyone may close it with a comment. The \`$STALE_LABEL\` label is removed automatically on the next update. <!-- $MARKER -->"
        gh issue comment "$num" --body "$body" >/dev/null
        gh issue edit "$num" --add-label "$STALE_LABEL" >/dev/null
        printf 'warned + labeled claim #%s (%s): %s\n' "$num" "$title" "$url"
        labeled=$((labeled + 1))
        continue
    fi

    # Not stale. If it still carries the label, drop it — but only on fresh
    # HUMAN activity (a marker comment that is still the last update means
    # nothing changed since the warning).
    if has_label "$labels" "$STALE_LABEL"; then
        if [ -n "$marker_ts" ]; then
            # updated_at <= the warning + epsilon => the label bump is the
            # only "update"; no human activity yet — keep the label.
            if [ $((upd_ts - marker_ts)) -le "$BUMP_EPSILON" ]; then
                already_flagged=$((already_flagged + 1))
                printf 'keep claim #%s (%s): flagged, no human update yet\n' "$num" "$title"
                continue
            fi
        fi
        if [ -n "$ISSUES_JSON" ] || [ "$DRY_RUN" -eq 1 ]; then
            printf 'unlabel claim #%s (%s): updated since the warning\n' "$num" "$title"
            unlabeled=$((unlabeled + 1))
            continue
        fi
        gh issue edit "$num" --remove-label "$STALE_LABEL" >/dev/null
        printf 'unlabeled claim #%s (%s): %s\n' "$num" "$title" "$url"
        unlabeled=$((unlabeled + 1))
    fi
done < <(printf '%s\n' "$json" | jq -c '.[]' 2>/dev/null)

printf 'sweep-stale-claims: checked %d open claim issue(s) — %d newly stale (warned+labeled), %d unlabeled, %d still flagged\n' \
    "$checked" "$stale" "$unlabeled" "$already_flagged"
