#!/usr/bin/env bash
#
# lint-workflows.sh -- lint the GitHub Actions workflows (class A).
#
# Runs actionlint over every workflow in .github/workflows/ so trigger and
# expression typos (event names, `if:` conditions, job keys, runner
# labels, ...) fail in CI instead of surfacing only when a workflow
# actually runs in production. The actionlint revision is pinned (below);
# the runner-label allowance lives in .github/actionlint.yaml.
#
# Also asserts class-A parity between the two places the portable set is
# written down: `just verify-portable` (the justfile recipe) and the step
# list of the macos job in .github/workflows/ci.yml. Copied lists drift,
# and this pair had: three class-A gates had silently stopped running in
# CI (inventory-gates.sh --check — the GF1 registration guard —,
# verify-ttf-fonts.sh, verify-vf-class-a.sh) while docs/testing.md claimed
# CI ran the inventory check. A gate that only runs locally cannot fail a
# merge, so the recipe is now asserted to be a subset of ci.yml. See the
# normalization rules at the check itself.
#
# Deterministic across hosts: shellcheck/pyflakes integrations are
# disabled (-shellcheck= -pyflakes=) so the result does not depend on
# which linters happen to be preinstalled on a runner — this check is
# about workflow structure and expressions.
#
# Uses `actionlint` from PATH when present (brew install actionlint),
# otherwise self-bootstraps the pinned release into .build/ (gitignored),
# so `just verify-portable` works on a clean checkout with no global
# install. Network is required only for the first bootstrap download.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="1.7.12"
BIN=""

# os_arch -- actionlint release asset suffix for this host. Kept as a
# function so the `case` never sits inside a command substitution (old
# bash 3.2 mis-parses `$(case ... esac)` and the repo runs on old bash
# until tools/env-check.sh is sourced).
os_arch() {
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64) echo darwin_arm64 ;;
        Darwin-x86_64) echo darwin_amd64 ;;
        Linux-x86_64) echo linux_x86_64 ;;
        Linux-aarch64) echo linux_arm64 ;;
        *)
            echo "lint-workflows.sh: unsupported platform: $(uname -s)-$(uname -m) (install actionlint on PATH)" >&2
            return 1 ;;
    esac
}

if command -v actionlint >/dev/null 2>&1; then
    BIN="$(command -v actionlint)"
else
    BIN="$ROOT/.build/actionlint-${VERSION}"
    if [ ! -x "$BIN" ]; then
        mkdir -p "$ROOT/.build"
        ARCH="$(os_arch)" || exit 1
        curl -fsSL -o "$BIN.tgz" \
            "https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}_${ARCH}.tar.gz"
        tar -xzf "$BIN.tgz" -C "$ROOT/.build" actionlint
        mv "$ROOT/.build/actionlint" "$BIN"
        rm -f "$BIN.tgz"
    fi
fi

# No file arguments: actionlint auto-discovers .github/workflows/ and reads
# .github/actionlint.yaml from the repository root. It runs first so both
# checks report in one pass, and its exit status is preserved.
set +e
"$BIN" -shellcheck= -pyflakes= -no-color
LINT_RC=$?
set -e

# --- class-A parity: the justfile recipe must be a subset of ci.yml --------
#
# Normalization, and nothing else: `zig fmt --check <globs>` compares as
# `zig fmt --check` (the two lists legitimately cover different file sets)
# and `zig build <target>` compares as `zig build <target>` with flags
# dropped. Every other line compares whole, arguments included, so
# `inventory-gates.sh --check` can never be silently downgraded to the
# report-rewriting `inventory-gates.sh`.
#
# RECIPE= / JUSTFILE= / CI_YML= override the inputs, so the drift test can
# run against fixtures without touching the real files.

RECIPE="${RECIPE:-verify-portable}"
JUSTFILE="${JUSTFILE:-$ROOT/justfile}"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"

# parity_key LINE -- the comparable identity of one command line.
# Kept `case`-based with BRE sed: this file must run under old bash too
# (tools/env-check.sh is what makes the modern one win).
parity_key() {
    local l="$1"
    l="$(printf '%s' "$l" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$l" in
        "run: "*) l="$(printf '%s' "$l" | sed -e 's/^run:[[:space:]]*//')" ;;
    esac
    case "$l" in
        "zig fmt"*) printf 'zig fmt --check' ; return ;;
        "zig build"*) printf '%s' "$(printf '%s' "$l" | sed 's/^\(zig build\( [^-][^ ]*\)\?\).*/\1/')" ; return ;;
    esac
    printf '%s' "$l"
}

# recipe_cmds -- the command lines of the recipe body (indented lines up to
# the next top-level recipe).
recipe_cmds() {
    awk -v r="$RECIPE" '
        $0 == r ":" { insec = 1; next }
        insec && /^[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line != "" && line !~ /^#/) print line
            next
        }
        insec { insec = 0 }
    ' "$JUSTFILE"
}

# ci_cmds -- the command lines of every `run:` step in the workflow (a
# multi-line `run: |` block contributes its indented command lines).
ci_cmds() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/^run:[[:space:]]*/, "", line)
            if (line ~ /^(bash|zig|swift)[[:space:]]/) print line
        }
    ' "$CI_YML"
}

ci_hay=$'\n'
while IFS= read -r c; do
    [ -n "$c" ] || continue
    ci_hay="${ci_hay}$(parity_key "$c")"$'\n'
done < <(ci_cmds)

PARITY_TOTAL=0
PARITY_MISSING=0
PARITY_LIST=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(parity_key "$line")"
    PARITY_TOTAL=$((PARITY_TOTAL + 1))
    # Newline-delimited exact match -- a plain substring test would let
    # `zig build` pass on the strength of `zig build image`.
    case "$ci_hay" in
        *$'\n'"$key"$'\n'*) ;;
        *)
            PARITY_MISSING=$((PARITY_MISSING + 1))
            PARITY_LIST="${PARITY_LIST}    - ${key}"$'\n'
            ;;
    esac
done < <(recipe_cmds)

if [ "$PARITY_MISSING" -eq 0 ]; then
    echo "lint-workflows: class-A parity OK -- all $PARITY_TOTAL command(s) of 'just $RECIPE' are run by $CI_YML"
else
    echo "lint-workflows: class-A parity FAILED -- $PARITY_MISSING of $PARITY_TOTAL command(s) of 'just $RECIPE' are NOT run by $CI_YML:" >&2
    printf '%s' "$PARITY_LIST" >&2
    echo "  Add the missing step(s) to $CI_YML: a gate that only runs locally cannot fail a merge." >&2
    exit 1
fi

exit "$LINT_RC"
