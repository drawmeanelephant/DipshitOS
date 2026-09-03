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
# .github/actionlint.yaml from the repository root.
exec "$BIN" -shellcheck= -pyflakes= -no-color
