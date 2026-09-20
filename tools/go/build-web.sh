#!/usr/bin/env bash
#
# build-web.sh -- build an in-guest Go program (the browser) with the
# GOOS=virelai fork toolchain, the same way tools/go/build-go.sh builds the
# runtime fixtures.
#
# Usage: bash tools/go/build-web.sh [dir-under-user/go] [NAME]
#   Default: browser -> .build/go/WEB.ELF, fetch -> .build/go/GOFETCH.ELF
#
# The default NAME is not cosmetic: an app looks itself up by its executable
# name to find the WM (vi.WmPeers), so a binary built under a name the app does
# not claim resolves no self and its WM request returns false BEFORE sending --
# a silent no-op with no log line. Both apps below pin their own name in
# source (appName in user/go/browser/main.go, user/go/fetch/main.go), so the
# default has to match it; anything else gets the uppercased directory, exactly
# as before.
#
# HTTPS consumers (fetch, browser) import virelai/tls and dial in-process.
# Do not stage FETCHS.BIN for those apps.
#
# Imports are written as `virelai/...` so the module path and the GOPATH path
# agree: the host `go test ./...` run uses user/go/go.mod, and this script
# points GOPATH at a temp dir with user/go linked as $GOPATH/src/virelai.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="${1:-browser}"
case "$DIR" in
    browser) DEFAULT_NAME=WEB ;;
    fetch)   DEFAULT_NAME=GOFETCH ;;
    *)       DEFAULT_NAME="$(printf '%s' "$DIR" | tr '[:lower:]' '[:upper:]')" ;;
esac
NAME="${2:-$DEFAULT_NAME}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-web: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
mkdir -p "$GOPATH_DIR/src"
ln -sfn "$REPO/user/go" "$GOPATH_DIR/src/virelai"

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export GO111MODULE=off
export GOFLAGS=
export GOPATH="$GOPATH_DIR"
export CGO_ENABLED=0

OUT_DIR="$REPO/.build/go"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.ELF"

log "building virelai/$DIR -> $OUT"
( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -o "$OUT" -ldflags "-s -w" "virelai/$DIR" )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds exec_program_max ($MAX_BYTES); the kernel loader will refuse it"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
