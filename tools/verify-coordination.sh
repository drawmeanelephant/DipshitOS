#!/usr/bin/env bash
#
# verify-coordination.sh -- gate for the multiagent coordination surface.
#
# Checks that:
#   1. Every claim file (docs/claims/NNNN-slug.md) is well-formed: correct
#      filename, unique number, Owner field, Status field starting with one
#      of the status emoji (⬜ 🔄 ✅ ⛔).
#   2. Every branch log (docs/logs/*.md, except README.md) opens with a
#      "# Log — <title>" header.
#   3. The generated index tables in docs/claims/README.md and
#      docs/logs/README.md are in sync with the actual files.
#   4. docs/status.md stays an edit-free coordination surface: no changelog
#      entries, no claims table, no march/agent-split tables (those live in
#      docs/logs/, docs/claims/README.md, and docs/march-m15.md).
#
# Run before opening a PR (`just verify-coordination`; also runs in CI).
# If it fails, fix the file(s) it names and/or run:
#     bash tools/status/refresh-indexes.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
bad() { printf 'error: %s\n' "$*" >&2; fail=1; }

# --- claim files -----------------------------------------------------------

claim_files="$(ls docs/claims/[0-9][0-9][0-9][0-9]-*.md 2>/dev/null || true)"
seen=""
for f in $claim_files; do
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
done

# --- branch logs ------------------------------------------------------------

for f in docs/logs/*.md; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    # Canonical header uses an em dash; refresh-indexes.sh tolerates a
    # plain hyphen when deriving the index title, but new logs must use the
    # em-dash form so the gate stays strict.
    head -1 "$f" | grep -q '^# Log — ' || bad "$(basename "$f"): first line must be '# Log — <title>'"
done

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
    bad "docs/status.md must not contain the march table — update docs/march-m15.md"
fi
if grep -qE '^## Best agent split|^\| Agent \| Owns \|' docs/status.md; then
    bad "docs/status.md must not contain the agent-split table — see docs/march-m15.md"
fi
[ -f docs/march-m15.md ] || bad "docs/march-m15.md missing (docs/status.md points to it)"

# --- generated index sync ---------------------------------------------------

if ! bash tools/status/refresh-indexes.sh --check; then
    bad "indexes out of sync — run: bash tools/status/refresh-indexes.sh"
fi

if [ "$fail" -ne 0 ]; then
    printf 'verify-coordination: FAILED\n' >&2
    exit 1
fi
printf 'verify-coordination: ok\n'
