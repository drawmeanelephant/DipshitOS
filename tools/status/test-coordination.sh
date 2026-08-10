#!/usr/bin/env bash
#
# test-coordination.sh -- self-contained tests for the coordination tooling
# (refresh-indexes.sh, claim-id.sh, verify-coordination.sh), run against a
# throwaway sandbox copy so the real repo is never modified.
#
# Positive cases:
#   1. claim-id.sh is deterministic, maps into [0024, 9999], and rejects
#      non-kebab slugs.
#   2. A claim whose Status contains '|' and '\' is escaped in the generated
#      index table: the table stays structurally valid and both --check and
#      verify-coordination pass.
#   3. A claim numbered with claim-id.sh passes verify-coordination.
# Negative cases:
#   4. A raw '|' in a table row (exactly what a broken, unescaping generator
#      emits) fails refresh-indexes.sh --check via structural validation.
#   5. A hand-sequenced claim number (0024) fails verify-coordination with
#      the deterministic-ID error.
#
# Usage: bash tools/status/test-coordination.sh
# (also `just test-coordination` and CI)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { echo "ok:   $1"; pass=$((pass + 1)); }
nope() { echo "FAIL: $1"; fail=$((fail + 1)); }

# --- sandbox ----------------------------------------------------------------
mkdir -p "$TMP/tools/status" "$TMP/docs/claims" "$TMP/docs/logs"
cp "$ROOT/tools/status/refresh-indexes.sh" "$TMP/tools/status/"
cp "$ROOT/tools/status/claim-id.sh"         "$TMP/tools/status/"
cp "$ROOT/tools/verify-coordination.sh"     "$TMP/tools/"
# verify-coordination.sh requires these files to exist
: > "$TMP/docs/status.md"
: > "$TMP/docs/march-m3.md"

cat > "$TMP/docs/claims/README.md" <<'EOF'
# Active claims (sandbox fixture)
<!-- CLAIMS_INDEX:START -->
<!-- CLAIMS_INDEX:END -->
EOF

cat > "$TMP/docs/logs/README.md" <<'EOF'
# Coordination logs (sandbox fixture)
<!-- LOGS_INDEX:START -->
<!-- LOGS_INDEX:END -->
EOF

# legacy (grandfathered, <= 0023) claim whose Status contains a pipe + backslash
cat > "$TMP/docs/claims/0001-fixture.md" <<'EOF'
# Claim: fixture

- **Owner:** test-agent (`branch/one`)
- **Status:** 🔄 in progress — see `x|y` and `a\b`
- **Depends on:** —
EOF

# log whose title contains a pipe
cat > "$TMP/docs/logs/branch-one.md" <<'EOF'
# Log — Fixture | branch one

- **2026-08-08** — *test-agent*: fixture entry.
EOF

run() { ( cd "$TMP" && "$@" ); }

# --- 1. claim-id.sh determinism / range / slug validation -------------------
id1="$(bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'some-slug')"
id2="$(bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'some-slug')"
if [ "$id1" = "$id2" ]; then
    ok "claim-id.sh is deterministic ($id1)"
else
    nope "claim-id.sh not deterministic: $id1 vs $id2"
fi

id3="$(bash "$TMP/tools/status/claim-id.sh" 'branch/two' 'some-slug')"
if [ "$id1" != "$id3" ]; then
    ok "claim-id.sh differs across branches ($id1 vs $id3)"
else
    nope "claim-id.sh gives the same ID for different branches"
fi

id4="$(bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'other-slug')"
if [ "$id1" != "$id4" ]; then
    ok "claim-id.sh differs across slugs ($id1 vs $id4)"
else
    nope "claim-id.sh gives the same ID for different slugs"
fi

for id in "$id1" "$id3"; do
    n=$((10#$id))
    if [ "$n" -ge 24 ] && [ "$n" -le 9999 ]; then
        ok "claim-id.sh maps into [0024, 9999] ($id)"
    else
        nope "claim-id.sh out of range: $id"
    fi
done

if bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'Bad Slug!' >/dev/null 2>&1; then
    nope "claim-id.sh accepted a non-kebab slug"
else
    ok "claim-id.sh rejects a non-kebab slug"
fi

# --- 2. positive: pipes/backslashes in claim status must not break the index
run bash tools/status/refresh-indexes.sh >/dev/null

if grep -Fq 'see `x\|y` and `a\\b`' "$TMP/docs/claims/README.md"; then
    ok "claim status '|' and '\' escaped in the index table"
else
    nope "claim status not escaped in the index table"
fi
if grep -Fq 'Fixture \| branch one' "$TMP/docs/logs/README.md"; then
    ok "log title '|' escaped in the log index table"
else
    nope "log title not escaped in the log index table"
fi

if run bash tools/status/refresh-indexes.sh --check >/dev/null 2>&1; then
    ok "--check passes with escaped pipes/backslashes"
else
    nope "--check failed after refresh with escaped content"
fi
if run bash tools/verify-coordination.sh >/dev/null 2>&1; then
    ok "verify-coordination passes with escaped pipes/backslashes"
else
    nope "verify-coordination failed with escaped pipes/backslashes"
fi

# --- 3. positive: a claim numbered with claim-id.sh passes the gate ---------
derived="$(bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'derived-fixture')"
cat > "$TMP/docs/claims/${derived}-derived-fixture.md" <<EOF
# Claim: derived fixture

- **Owner:** test-agent (\`branch/one\`)
- **Status:** ✅ done
- **Depends on:** —
EOF
run bash tools/status/refresh-indexes.sh >/dev/null
if run bash tools/verify-coordination.sh >/dev/null 2>&1; then
    ok "derived-numbered claim ${derived} passes verify-coordination"
else
    nope "derived-numbered claim ${derived} failed verify-coordination"
fi

# --- 4. negative: a raw '|' in a table row fails structural validation ------
# What a broken (unescaping) generator emits: a pipe straight into a cell.
sed 's/see `x\\|y`/see `x|y`/' "$TMP/docs/claims/README.md" > "$TMP/docs/claims/README.md.new"
mv "$TMP/docs/claims/README.md.new" "$TMP/docs/claims/README.md"

out="$(run bash tools/status/refresh-indexes.sh --check 2>&1 || true)"
case "$out" in
    *"structurally malformed"*)
        ok "--check fails on a table row with a raw '|' (structural validation)" ;;
    *)
        nope "--check did not report the raw '|' row: $out" ;;
esac
if run bash tools/verify-coordination.sh >/dev/null 2>&1; then
    nope "verify-coordination accepted a table with a raw '|'"
else
    ok "verify-coordination fails on a table with a raw '|'"
fi

# --- 5. negative: a hand-sequenced 0024+ claim fails the deterministic-ID gate
hs="$(bash "$TMP/tools/status/claim-id.sh" 'branch/one' 'hand-sequenced')"
if [ "$hs" = "0024" ]; then
    echo "skip: slug 'hand-sequenced' happens to derive to 0024; pick another" >&2
else
    run bash tools/status/refresh-indexes.sh >/dev/null   # restore the clean table
    cat > "$TMP/docs/claims/0024-hand-sequenced.md" <<'EOF'
# Claim: hand sequenced

- **Owner:** test-agent (`branch/one`)
- **Status:** ✅ done
- **Depends on:** —
EOF
    run bash tools/status/refresh-indexes.sh >/dev/null
    out="$(run bash tools/verify-coordination.sh 2>&1 || true)"
    case "$out" in
        *"does not match the deterministic ID"*)
            ok "hand-sequenced 0024 claim fails the deterministic-ID gate" ;;
        *)
            nope "hand-sequenced 0024 claim was not rejected: $out" ;;
    esac
    rm -f "$TMP/docs/claims/0024-hand-sequenced.md"
fi

# --- final: clean sandbox passes -------------------------------------------
run bash tools/status/refresh-indexes.sh >/dev/null
if run bash tools/verify-coordination.sh >/dev/null 2>&1; then
    ok "final clean sandbox passes verify-coordination"
else
    nope "final clean sandbox failed verify-coordination"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "test-coordination: all $pass tests passed"
else
    echo "test-coordination: $fail of $((pass + fail)) tests FAILED" >&2
    exit 1
fi
