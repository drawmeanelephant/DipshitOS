#!/usr/bin/env bash
#
# verify-coordination.sh -- gate for the multiagent coordination surface.
#
# Checks that:
#   1. Every claim file (docs/claims/NNNN-slug.md) is well-formed: correct
#      filename, unique number, Owner field, Status field starting with one
#      of the status emoji (⬜ 🔄 ✅ ⛔).
#   2. Every claim numbered 0024+ carries the deterministic claim ID derived
#      from its owner branch + filename slug (tools/status/claim-id.sh), so
#      concurrent claimers cannot pick the same number; 0001-0023 are
#      grandfathered sequential numbers.
#   3. Every branch log (docs/logs/*.md, except README.md) opens with a
#      "# Log — <title>" header.
#   4. The generated index tables in docs/claims/README.md and
#      docs/logs/README.md are structurally valid (markers present, every
#      row has the expected column count, so an unescaped '|' cannot
#      corrupt a table). Sync with the claim/log files is NOT checked here:
#      since claim 2599 branches do not regenerate or commit the tables —
#      .github/workflows/indexes.yml opens a regeneration PR against main
#      after every merge,
#      so a branch's committed indexes are stale by design. (refresh-indexes
#      --check still enforces sync where it is meaningful: on main / bot.)
#   5. docs/status.md stays an edit-free coordination surface: no changelog
#      entries, no claims table, no march/agent-split tables (those live in
#      docs/logs/, docs/claims/README.md, and docs/march-m3.md; the
#      completed M1.5 tracker is archived at docs/archive/march-m15.md).
#
# Run before opening a PR (`just verify-coordination`; also runs in CI).
# If it fails, fix the file(s) it names. Index tables are regenerated on
# main by CI (claim 2599); a local `bash tools/status/refresh-indexes.sh`
# is an optional preview only — do not commit its output from a branch.
#
# Tracked files only: this checkout is shared by concurrent agents, so
# another agent's UNTRACKED claim/log staging files must not fail this
# branch's gate (they are not part of what merges).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
bad() { printf 'error: %s\n' "$*" >&2; fail=1; }

# --- claim files -----------------------------------------------------------

claim_files="$(git ls-files -c -- 'docs/claims' | grep -E '/[0-9]{4}-[^/]*\.md$' | sort || true)"
seen=""
active_declared=""
now="$(date +%s)"
STALE_DAYS="${STALE_DAYS:-14}"

# tokens_overlap A B -- do two Touches tokens collide?
# Exact match, or either side is a `prefix*` glob matching the other.
tokens_overlap() {
    x="$1"; y="$2"
    [ "$x" = "$y" ] && return 0
    case "$x" in
        *\*) p="${x%\*}"; case "$y" in "$p"*) return 0 ;; esac ;;
    esac
    case "$y" in
        *\*) p="${y%\*}"; case "$x" in "$p"*) return 0 ;; esac ;;
    esac
    return 1
}

for f in $claim_files; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
        [0-9][0-9][0-9][0-9]-[a-z0-9-]*.md) ;;
        *) bad "claim file name must be NNNN-slug.md: $base" ;;
    esac
    num="${base%%-*}"
    case " $seen " in
        *" $num "*) bad "duplicate claim number $num ($base)" ;;
    esac
    seen="$seen $num"

    grep -q -- '^- \*\*Owner:\*\*' "$f" || bad "$base: missing '- **Owner:**' field"
    grep -q -- '^- \*\*Status:\*\*' "$f" || bad "$base: missing '- **Status:**' field"
    if ! grep -q -- '^- \*\*Status:\*\* ⬜' "$f" \
        && ! grep -q -- '^- \*\*Status:\*\* 🔄' "$f" \
        && ! grep -q -- '^- \*\*Status:\*\* ✅' "$f" \
        && ! grep -q -- '^- \*\*Status:\*\* ⛔' "$f"; then
        bad "$base: Status must start with one of ⬜ 🔄 ✅ ⛔"
    fi
    # Deterministic claim-ID check (0024+). The sequential "next NNNN"
    # convention collided once already (claim 0013 -> 0014, commit be811cb):
    # two agents both picked the next free number. Claims 0001-0023 are
    # grandfathered sequential numbers; 0024+ must equal the ID derived from
    # the owner branch + filename slug (tools/status/claim-id.sh), a pure
    # function of the claim itself, so concurrent claimers cannot collide.
    n=$((10#$num))
    if [ "$n" -ge 24 ]; then
        slug="${base#????-}"
        slug="${slug%.md}"
        branch="$(sed -n 's/^- \*\*Owner:\*\* [^`]*`\([^`]*\)`.*/\1/p' "$f" | head -1)"
        if [ -z "$branch" ]; then
            bad "$base: Owner must include a backticked branch (needed for the deterministic claim ID)"
        else
            want="$(bash tools/status/claim-id.sh "$branch" "$slug")"
            if [ "$num" != "$want" ]; then
                bad "$base: claim number $num does not match the deterministic ID $want (renumber with: bash tools/status/claim-id.sh \"$branch\" \"$slug\")"
            fi
        fi
    fi

    # --- claim lifecycle: Touches conflicts + staleness (#523 items 4-5) ---
    # Only ACTIVE (🔄) claims participate. Fields are optional so the
    # grandfathered claim files stay valid.
    status_line="$(sed -n 's/^- \*\*Status:\*\* //p' "$f" | head -1)"
    case "$status_line" in
        🔄*)
            ab="$(sed -n 's/^- \*\*Owner:\*\* [^`]*`\([^`]*\)`.*/\1/p' "$f" | head -1)"
            touches="$(sed -n 's/^- \*\*Touches:\*\* //p' "$f" | head -1 | tr ',' ' ')"
            last_ts="$(git log -1 --format=%ct -- "$f" 2>/dev/null || true)"
            if [ -n "$last_ts" ]; then
                age_days=$(( (now - last_ts) / 86400 ))
                if [ "$age_days" -ge "$STALE_DAYS" ]; then
                    printf 'warn: %s: 🔄 for %d days — update the Heartbeat (commit the claim file) or, past ~21 days, anyone may flip it ⛔ with a log entry\n' "$base" "$age_days" >&2
                fi
            fi
            for t in $touches; do
                [ -n "$ab" ] || break
                active_declared="${active_declared}${ab} ${t}
"
            done
            ;;
    esac
done

# Pairwise overlap between ACTIVE claims from different branches.
# Reported once per unordered pair.
if [ -n "$active_declared" ]; then
    while read -r b1 t1; do
        [ -n "$t1" ] || continue
        while read -r b2 t2; do
            [ -n "$t2" ] || continue
            [ "$b1" != "$b2" ] || continue
            if [[ "$b1$t1" < "$b2$t2" ]]; then continue; fi
            if tokens_overlap "$t1" "$t2"; then
                bad "ACTIVE claims from '$b1' and '$b2' both declare '$t1' / '$t2' — one editor per file: coordinate, or wait for the other claim to land"
            fi
        done <<EOF2
$active_declared
EOF2
    done <<EOF1
$active_declared
EOF1
fi

# --- branch logs ------------------------------------------------------------

while IFS= read -r f; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    # Canonical header uses an em dash; refresh-indexes.sh tolerates a
    # plain hyphen when deriving the index title, but new logs must use the
    # em-dash form so the gate stays strict.
    head -1 "$f" | grep -q '^# Log — ' || bad "$(basename "$f"): first line must be '# Log — <title>'"
done < <(git ls-files -c -- 'docs/logs' | grep -E '\.md$' | sort)

# --- docs/status.md invariants (keep it an edit-free pointer surface) -------

# Content-based tripwires (not just heading names) so a re-added march or
# agent-split table is caught under any heading.
if grep -qE '^- \*\*20[0-9]{2}-' docs/status.md; then
    bad "docs/status.md must not contain changelog entries — append to docs/logs/<branch>.md"
fi
if grep -qE '^\| \[[0-9]{4}-' docs/status.md; then
    bad "docs/status.md must not contain a claims table — see docs/claims/README.md"
fi
if grep -qE 'Legend: ⬜ not started|^\| # \| Step \|' docs/status.md; then
    bad "docs/status.md must not contain the march table — update docs/march-m3.md"
fi
if grep -qE '^## Best agent split|^\| Agent \| Owns \|' docs/status.md; then
    bad "docs/status.md must not contain the agent-split table — see docs/march-m3.md"
fi
[ -f docs/march-m3.md ] || bad "docs/march-m3.md missing (docs/status.md points to it)"

# --- generated index integrity (sync is enforced by CI on main, not here) ---

if ! bash tools/status/refresh-indexes.sh --check-structure >/dev/null; then
    bad "index tables malformed (markers missing or a row has the wrong column count)"
fi

if [ "$fail" -ne 0 ]; then
    printf 'verify-coordination: FAILED\n' >&2
    exit 1
fi
printf 'verify-coordination: ok\n'
