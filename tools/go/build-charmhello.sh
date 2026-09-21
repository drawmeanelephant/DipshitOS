#!/usr/bin/env bash
#
# build-charmhello.sh -- build M72c's Bubble Tea / bound-tty hello with the
# GOOS=virelai fork. Charm stays in the Go module cache: no vendor tree,
# README dump, or host ANSI renderer is copied into this repository.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
NAME="${GO_BUILD_NAME:-CHARMHELLO}"
VERSION="v2.0.9"
MAX_BYTES=$((32 * 1024 * 1024)) # M72a load_max: initialized ELF bytes.

log() { printf 'build-charmhello: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# Fetch only declared Go modules into the host module cache. The app build
# remains module-mode so Charm's transitive packages resolve there; no source
# from that cache is committed or vendored into the guest tree.
( cd "$REPO/user/go" && go mod download "charm.land/bubbletea/v2@${VERSION}" )

MOD_DIR="$(go env GOMODCACHE)/charm.land/bubbletea/v2@${VERSION}"
[ -f "$MOD_DIR/termios_other.go" ] || {
    log "Bubble Tea ${VERSION} missing from module cache at $MOD_DIR"
    exit 1
}

# Go intentionally refuses overlays beneath GOMODCACHE. Stage the one module
# into the gitignored build area, then point a temporary module file at it:
# this is still a module-cache build, not an in-tree vendor copy, and makes
# the two Virelai-only files visible to the compiler without mutating Charm.
STAGE="$REPO/.build/charmhello-module"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$MOD_DIR/." "$STAGE/"

OVERLAY="$REPO/.build/charmhello-overlay.json"
MODFILE="$REPO/.build/charmhello.mod"
mkdir -p "$(dirname "$OVERLAY")" "$REPO/.build/go"
python3 - "$STAGE" "$REPO" "$OVERLAY" "$MODFILE" <<'PY'
import json, os, sys

module, repo, out, modfile = sys.argv[1:]
replace = {
    # These originals are selected for an unknown GOOS; the overlay changes
    # their build tags and supplies the four Program platform hooks without
    # pretending Virelai has termios or POSIX signals.
    os.path.join(module, "termios_other.go"): os.path.join(repo, "tools/go/overlay/charm/termios_virelai.go"),
    os.path.join(module, "signals_unix.go"): os.path.join(repo, "tools/go/overlay/charm/signals_virelai.go"),
}
with open(out, "w") as f:
    json.dump({"Replace": replace}, f, sort_keys=True)

source = open(os.path.join(repo, "user/go/go.mod")).read()
source = source.replace(
    "replace virelai/tools/go/tabcodec => ../../tools/go/tabcodec",
    "replace virelai/tools/go/tabcodec => " + os.path.join(repo, "tools/go/tabcodec"),
)
source += "\nreplace charm.land/bubbletea/v2 => " + module + "\n"
with open(modfile, "w") as f:
    f.write(source)
PY

OUT="$REPO/.build/go/$NAME.ELF"
log "building virelai/charmhello with Bubble Tea ${VERSION} -> $OUT"
( cd "$REPO/user/go" &&
    GOOS=virelai GOARCH=arm64 go build -mod=mod -modfile "$MODFILE" -overlay "$OVERLAY" \
        -ldflags "-s -w" -o "$OUT" ./charmhello )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds M72a load_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (<= M72a 32 MiB initialized-image bound; module-cache Charm, no vendor tree)"
