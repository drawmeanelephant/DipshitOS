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
#   refresh-indexes.sh                  # regenerate the tables in place
#   refresh-indexes.sh --check          # verify the tables match the files (exit 1 if not)
#   refresh-indexes.sh --check-structure  # markers + column count only, no sync diff
#
# Generated cell content (claim Owner/Status, log titles) is escaped for
# Markdown tables (| -> \|, \ -> \\) so a literal pipe in a claim file can
# never widen (and corrupt) the index table. Both check modes validate the
# table structure row-by-row (every row must have the exact expected number
# of columns), so a table cannot pass merely because it matches a broken
# generator's own output.
#
# The tables live between marker comments; the surrounding prose is kept
# as-is:
#   <!-- CLAIMS_INDEX:START --> ... <!-- CLAIMS_INDEX:END -->
#   <!-- LOGS_INDEX:START --> ... <!-- LOGS_INDEX:END -->
#
# Tracked files only: the indexes are generated from files known to git
# (git ls-files), never from a raw directory glob.
#
# WHO RUNS THIS: since claim 2599, branches do NOT regenerate or commit the
# index tables — `.github/workflows/indexes.yml` opens an auto-merge
# regeneration PR against main after every merge (the only serialized
# writer of a shared derived artifact; branch protection forbids direct
# pushes). Branch-side runs are an optional local preview of what
# the table will look like; do not commit the result. The PR-side
# coordination gate uses --check-structure (drift cannot fail a PR, because
# a PR's committed indexes are stale by design); the bot and humans use
# --check, which still fails on drift where drift is meaningful (main).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

MODE="${1:-refresh}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- generated table bodies ---------------------------------------------

# esc CELL -- make CELL safe inside a Markdown table cell: escape backslashes
# first, then pipes, so a literal "\|" in the source cannot re-introduce an
# unescaped pipe into the generated table.
esc() {
    printf '%s\n' "$1" | awk '{ gsub(/\\/, "\\\\"); gsub(/\|/, "\\|"); printf "%s", $0 }'
}

claims_index() {
    local f num owner status
    printf '| Claim | Owner (branch) | Status |\n'
    printf '|-------|----------------|--------|\n'
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -e "$f" ] || continue
        num="$(basename "$f" .md)"
        owner="$(sed -n 's/^- \*\*Owner:\*\* //p' "$f" | head -1)"
        status="$(sed -n 's/^- \*\*Status:\*\* //p' "$f" | head -1)"
        printf '| [%s](%s) | %s | %s |\n' "$num" "$num.md" \
            "$(esc "${owner:-—}")" "$(esc "${status:-—}")"
    done < <(git ls-files -c -- 'docs/claims' | grep -E '/[0-9]{4}-[^/]*\.md$' | sort)
}

logs_index() {
    local f b title
    printf '| Branch | Log file |\n'
    printf '|--------|----------|\n'
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        b="$(basename "$f")"
        [ "$b" = "README.md" ] && continue
        title="$(head -1 "$f" | sed 's/^# Log — //; s/^# Log - //')"
        printf '| %s | [`%s`](%s) |\n' "$(esc "${title:-$b}")" "$b" "$b"
    done < <(git ls-files -c -- 'docs/logs' | grep -E '\.md$' | sort)
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

# validate_table FILE MARKER CELLS
# Every row in the region (header, separator, and data) must have exactly
# CELLS columns once escaped pipes are taken into account. Catches a broken
# generator (or hand-edit) that lets a raw '|' into a cell, which the plain
# --check diff cannot: --check only proves the table matches the generator's
# own output, and a broken generator is consistent with itself.
validate_table() {
    local file="$1" marker="$2" cells="$3"
    local expect=$((cells + 2))  # fields after splitting on '|' == cells + 2
    extract_region "$file" "$marker" | awk -v expect="$expect" -v marker="$marker" -v cells="$cells" '
        {
            gsub(/\\\|/, "PIPE")       # an escaped pipe is cell content
            n = split($0, a, "|")
            if (n != expect) {
                printf "error: %s row %d has %d cells (expected %d): %s\n", \
                    marker, NR, n - 2, cells, $0 > "/dev/stderr"
                bad = 1
            }
        }
        END { if (bad) exit 1 }
    '
}

require_markers() { # FILE MARKER
    grep -q -- "<!-- $2:START -->" "$1" && grep -q -- "<!-- $2:END -->" "$1"
}

# --- modes ----------------------------------------------------------------

check_mode() {
    local rc=0
    check_structure || rc=1
    if [ "$rc" -eq 0 ]; then
        extract_region docs/claims/README.md CLAIMS_INDEX > "$tmp/claims.actual"
        if ! diff -u "$tmp/claims.actual" "$tmp/claims.table"; then
            echo "error: docs/claims/README.md claim index is out of sync" >&2
            rc=1
        fi
        extract_region docs/logs/README.md LOGS_INDEX > "$tmp/logs.actual"
        if ! diff -u "$tmp/logs.actual" "$tmp/logs.table"; then
            echo "error: docs/logs/README.md log index is out of sync" >&2
            rc=1
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        echo "coordination indexes are in sync"
    else
        echo "hint: run: bash tools/status/refresh-indexes.sh" >&2
    fi
    return "$rc"
}

# Structure-only validation: markers present and every row well-formed.
# No sync diff — used by verify-coordination.sh on PRs, where a branch's
# committed indexes are stale by design (the bot regenerates on main).
check_structure() {
    local rc=0
    require_markers docs/claims/README.md CLAIMS_INDEX || {
        echo "error: CLAIMS_INDEX markers missing from docs/claims/README.md" >&2
        rc=1
    }
    require_markers docs/logs/README.md LOGS_INDEX || {
        echo "error: LOGS_INDEX markers missing from docs/logs/README.md" >&2
        rc=1
    }
    [ "$rc" -eq 0 ] || return 1
    # Structural validation: a table that matches a broken generator's own
    # output must still fail here.
    if ! validate_table docs/claims/README.md CLAIMS_INDEX 3; then
        echo "error: docs/claims/README.md claim index is structurally malformed (a cell contains an unescaped '|'?)" >&2
        rc=1
    fi
    if ! validate_table docs/logs/README.md LOGS_INDEX 2; then
        echo "error: docs/logs/README.md log index is structurally malformed (a cell contains an unescaped '|'?)" >&2
        rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        echo "coordination indexes are structurally valid"
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
    --check-structure) check_structure ;;
    refresh) refresh_mode ;;
    *)
        echo "usage: refresh-indexes.sh [--check|--check-structure]" >&2
        exit 2
        ;;
esac
