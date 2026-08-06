#!/usr/bin/env bash
#
# refresh-indexes.sh -- regenerate the shared coordination index tables.
#
# The index tables in docs/claims/README.md and docs/logs/README.md are
# derived from the actual claim/log files, so agents never hand-edit a
# shared table (two agents appending to the same table collide on merge).
# Create your claim file (docs/claims/NNNN-slug.md) or branch log
# (docs/logs/<branch>.md), then run this script.
#
# Usage:
#   refresh-indexes.sh          # regenerate the tables in place
#   refresh-indexes.sh --check  # verify the tables match the files (exit 1 if not)
#
# The tables live between marker comments; the surrounding prose is kept
# as-is:
#   <!-- CLAIMS_INDEX:START --> ... <!-- CLAIMS_INDEX:END -->
#   <!-- LOGS_INDEX:START --> ... <!-- LOGS_INDEX:END -->

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MODE="${1:-refresh}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- generated table bodies ---------------------------------------------

claims_index() {
    local f num owner status
    printf '| Claim | Owner (branch) | Status |\n'
    printf '|-------|----------------|--------|\n'
    for f in docs/claims/[0-9][0-9][0-9][0-9]-*.md; do
        [ -e "$f" ] || continue
        num="$(basename "$f" .md)"
        owner="$(sed -n 's/^- \*\*Owner:\*\* //p' "$f" | head -1)"
        status="$(sed -n 's/^- \*\*Status:\*\* //p' "$f" | head -1)"
        printf '| [%s](%s) | %s | %s |\n' "$num" "$num.md" "${owner:-—}" "${status:-—}"
    done
}

logs_index() {
    local f b title
    printf '| Branch | Log file |\n'
    printf '|--------|----------|\n'
    for f in docs/logs/*.md; do
        b="$(basename "$f")"
        [ "$b" = "README.md" ] && continue
        title="$(head -1 "$f" | sed 's/^# Log — //; s/^# Log - //')"
        printf '| %s | [`%s`](%s) |\n' "${title:-$b}" "$b" "$b"
    done
}

# --- region splicing helpers ---------------------------------------------

# splice_region FILE MARKER CONTENT_FILE
# Replace everything between "<!-- MARKER:START -->" and "<!-- MARKER:END -->"
# in FILE with the contents of CONTENT_FILE (the marker lines are kept).
splice_region() {
    local file="$1" marker="$2" content="$3"
    awk -v start="<!-- $marker:START -->" -v end="<!-- $marker:END -->" \
        -v content="$content" '
        BEGIN { active = 0 }
        $0 == start { print; active = 1; while ((getline line < content) > 0) print line; close(content); next }
        $0 == end   { active = 0 }
        { if (active == 0) print }
    ' "$file" > "$tmp/region" && mv "$tmp/region" "$file"
}

# extract_region FILE MARKER  -> the current region content (markers excluded)
extract_region() {
    awk -v start="<!-- $2:START -->" -v end="<!-- $2:END -->" '
        BEGIN { active = 0 }
        $0 == start { active = 1; next }
        $0 == end   { active = 0; next }
        { if (active) print }
    ' "$1"
}

require_markers() { # FILE MARKER
    grep -q -- "<!-- $2:START -->" "$1" && grep -q -- "<!-- $2:END -->" "$1"
}

# --- modes ----------------------------------------------------------------

check_mode() {
    local rc=0
    require_markers docs/claims/README.md CLAIMS_INDEX || {
        echo "error: CLAIMS_INDEX markers missing from docs/claims/README.md" >&2
        rc=1
    }
    require_markers docs/logs/README.md LOGS_INDEX || {
        echo "error: LOGS_INDEX markers missing from docs/logs/README.md" >&2
        rc=1
    }
    if [ "$rc" -ne 0 ]; then return 1; fi
    if ! diff -u <(extract_region docs/claims/README.md CLAIMS_INDEX) "$tmp/claims.table"; then
        echo "error: docs/claims/README.md claim index is out of sync" >&2
        rc=1
    fi
    if ! diff -u <(extract_region docs/logs/README.md LOGS_INDEX) "$tmp/logs.table"; then
        echo "error: docs/logs/README.md log index is out of sync" >&2
        rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        echo "coordination indexes are in sync"
    else
        echo "hint: run: bash tools/status/refresh-indexes.sh" >&2
    fi
    return "$rc"
}

refresh_mode() {
    # Splice the generated tables in, then re-verify so a silent no-op
    # (e.g. a marker line with trailing whitespace) cannot slip through.
    splice_region docs/claims/README.md CLAIMS_INDEX "$tmp/claims.table"
    splice_region docs/logs/README.md LOGS_INDEX "$tmp/logs.table"
    echo "refreshed docs/claims/README.md and docs/logs/README.md"
    check_mode
}

claims_index > "$tmp/claims.table"
logs_index > "$tmp/logs.table"

case "$MODE" in
    --check) check_mode ;;
    refresh) refresh_mode ;;
    *)
        echo "usage: refresh-indexes.sh [--check]" >&2
        exit 2
        ;;
esac
