#!/usr/bin/env bash
#
# build-help.sh -- build GOHELP.ELF, the M74c (issue #1646) Charm help
# browser (user/go/help), with the GOOS=virelai fork. Charm stays in the Go
# module cache — staged and overlaid like build-charmhello.sh/
# build-files.sh, never vendored in-tree. Output: .build/go/GOHELP.ELF
#
# Usage: bash tools/go/build-help.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
NAME="${GO_BUILD_NAME:-GOHELP}"
VERSION="v2.0.9"
MAX_BYTES=$((32 * 1024 * 1024)) # M72a load_max (exec_image_max): initialized ELF bytes.

log() { printf 'build-help: %s\n' "$*"; }

# MIT/BSD attribution for the Charm modules linked into the ELF lives in
# user/go/help/THIRD-PARTY.txt (sources stay in the module cache, so the
# notice has to ship separately). A version bump without re-resolving that
# file must fail here, not silently ship stale notices.
if ! grep -q "bubbletea/v2 ${VERSION}" "$REPO/user/go/help/THIRD-PARTY.txt"; then
    log "FAIL: THIRD-PARTY.txt does not pin Bubble Tea ${VERSION}; re-resolve and update it"
    exit 1
fi

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# Charm is intentionally NOT a dependency of the SDK's user/go/go.mod:
# `user/go/ttf` guards that module against broad desktop dependencies. Start
# with a gitignored cache module, then build through a transient modfile
# beside the SDK's own go.mod (Go requires a -modfile to live in that
# directory).
WORK_DIR="$REPO/.build/help-work"
MODFILE="$WORK_DIR/go.mod"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cat >"$MODFILE" <<EOF
module help-build

go 1.27

require charm.land/bubbletea/v2 ${VERSION}
EOF

# Fetch the declared module into the host module cache. The app build
# remains module-mode so Charm's transitive packages resolve there; no
# source from that cache is committed or vendored into the guest tree.
( cd "$WORK_DIR" && go mod download "charm.land/bubbletea/v2@${VERSION}" )

MOD_DIR="$(go env GOMODCACHE)/charm.land/bubbletea/v2@${VERSION}"
[ -f "$MOD_DIR/termios_other.go" ] || {
    log "Bubble Tea ${VERSION} missing from module cache at $MOD_DIR"
    exit 1
}

# Go intentionally refuses overlays beneath GOMODCACHE. Stage the module
# into the gitignored build area, then point a temporary module file at it:
# this is still a module-cache build, not an in-tree vendor copy, and makes
# the two Virelai-only files visible to the compiler without mutating Charm.
STAGE="$REPO/.build/help-module"
if [ -d "$STAGE" ]; then
    # Module-cache sources are intentionally read-only; make a prior staged
    # copy removable before refreshing it.
    chmod -R u+w "$STAGE"
    rm -rf "$STAGE"
fi
mkdir -p "$STAGE"
cp -r "$MOD_DIR/." "$STAGE/"
chmod -R u+w "$STAGE"

# The two Virelai platform hooks: no termios, no POSIX signals — the same
# overlay build-charmhello.sh/build-pulse.sh/build-files.sh use
# (tools/go/overlay/charm).
OVERLAY="$REPO/.build/help-overlay.json"
mkdir -p "$(dirname "$OVERLAY")" "$REPO/.build/go"
python3 - "$STAGE" "$REPO" "$OVERLAY" <<'PY'
import json, os, sys

module, repo, out = sys.argv[1:]
replace = {
    # These originals are selected for an unknown GOOS; the overlay changes
    # their build tags and supplies the Program platform hooks without
    # pretending Virelai has termios or POSIX signals.
    os.path.join(module, "termios_other.go"): os.path.join(repo, "tools/go/overlay/charm/termios_virelai.go"),
    os.path.join(module, "signals_unix.go"): os.path.join(repo, "tools/go/overlay/charm/signals_virelai.go"),
}
with open(out, "w") as f:
    json.dump({"Replace": replace}, f, sort_keys=True)
PY

TEMP_MOD="$REPO/user/go/.help.mod"
TEMP_SUM="${TEMP_MOD%.mod}.sum"
cp "$REPO/user/go/go.mod" "$TEMP_MOD"
cat >>"$TEMP_MOD" <<EOF

require charm.land/bubbletea/v2 ${VERSION}

replace charm.land/bubbletea/v2 => $STAGE
EOF
trap 'rm -f "$TEMP_MOD" "$TEMP_SUM"' EXIT

OUT="$REPO/.build/go/$NAME.ELF"
log "building virelai/help with Bubble Tea ${VERSION} -> $OUT"
( cd "$REPO/user/go" &&
    GOOS=virelai GOARCH=arm64 go build -mod=mod -modfile "$TEMP_MOD" -overlay "$OVERLAY" \
        -ldflags "-s -w" -o "$OUT" ./help )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds M72a load_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (<= M72a 32 MiB initialized-image bound; module-cache Charm, no vendor tree)"
