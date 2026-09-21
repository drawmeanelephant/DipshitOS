#!/usr/bin/env bash
#
# build-rss.sh -- build the VirelaiOS RSS/Atom reader (RSS.ELF) with the
# GOOS=virelai fork toolchain, the same way tools/go/build-charmhello.sh builds
# M72c's CHARMHELLO.ELF.
#
# Charm stays in the Go module cache: no vendor tree, no host renderer, and no
# macOS/Linux target is ever produced. The overlay supplies the two Virelai-only
# Bubble Tea platform hooks (tools/go/overlay/charm/*), exactly as M72c does.
#
# This script deliberately performs no destructive shell command: every staging
# area is a fresh mktemp directory, so there is nothing to clean up and no
# existing path is ever removed.
#
# Usage: bash tools/go/build-rss.sh
#   GO_FORK_DIR   fork location (default ../go-virelai)
#   GO_BUILD_NAME output basename (default RSS)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
NAME="${GO_BUILD_NAME:-RSS}"
VERSION="v2.0.9"

# Guest loader bounds (M72a): 32 MiB of INITIALIZED bytes (Sigma filesz),
# 64 MiB of MAPPED bytes (Sigma memsz). The older 2 MiB exec_program_max does
# not apply to a gap-layout static Go image; see docs/status.md row 72.
MAX_INIT=$((32 * 1024 * 1024))
MAX_MAP=$((64 * 1024 * 1024))

TARGET_GOOS="virelai"
TARGET_GOARCH="arm64"

log() { printf 'build-rss: %s\n' "$*"; }
fail() { printf 'build-rss: FAIL: %s\n' "$*" >&2; exit 1; }

# --- target guard: the recipe itself names exactly one target --------------
# A darwin/linux GOOS= anywhere in this script is a hard error, so the recipe
# cannot silently grow a host build path.
if grep -nE 'GOOS=(darwin|linux|windows|freebsd)' "$0" >/dev/null 2>&1; then
    fail "recipe names a non-guest GOOS; the reader targets the guest only"
fi

# MIT/BSD attribution for the Charm modules linked into the ELF lives in
# user/go/rss/THIRD-PARTY.txt; a version bump without re-resolving it must fail
# here rather than ship stale notices.
if ! grep -q "bubbletea/v2 ${VERSION}" "$REPO/user/go/rss/THIRD-PARTY.txt"; then
    fail "THIRD-PARTY.txt does not pin Bubble Tea ${VERSION}; re-resolve and update it"
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

# Charm is intentionally NOT a dependency of the SDK's user/go/go.mod. Work in a
# private copy of the module so the repository tree is never mutated, and stage
# Charm from the module cache (never a vendor copy in-tree).
#
# The staging root must NOT live under $TMPDIR: on macOS the Go toolchain
# mis-resolves a directory-replace module rooted under /var/folders/... , so
# stage under the gitignored .build/ tree instead.
mkdir -p "$REPO/.build"
WORK="$(mktemp -d "$REPO/.build/rss-stage.XXXXXX")"
MR="$WORK/modroot"
mkdir -p "$MR"
cp -R "$REPO/user/go/." "$MR/"
python3 - "$MR/go.mod" "$REPO/tools/go/tabcodec" <<'PY'
import sys
p, tc = sys.argv[1], sys.argv[2]
s = open(p).read().replace("=> ../../tools/go/tabcodec", "=> " + tc)
open(p, "w").write(s)
PY

cat > "$WORK/work.mod" <<EOF
module rssbuild

go 1.27

require charm.land/bubbletea/v2 ${VERSION}
EOF
mkdir -p "$WORK/work"
cp "$WORK/work.mod" "$WORK/work/go.mod"
( cd "$WORK/work" && go mod download "charm.land/bubbletea/v2@${VERSION}" )

MOD_DIR="$(go env GOMODCACHE)/charm.land/bubbletea/v2@${VERSION}"
[ -f "$MOD_DIR/termios_other.go" ] || fail "Bubble Tea ${VERSION} missing from module cache at $MOD_DIR"
STAGE="$WORK/charm"
mkdir -p "$STAGE"
cp -a "$MOD_DIR/." "$STAGE/"
chmod -R u+w "$STAGE"

OVERLAY="$WORK/overlay.json"
python3 - "$STAGE" "$REPO" "$OVERLAY" <<'PY'
import json, os, sys

module, repo, out = sys.argv[1:]
replace = {
    os.path.join(module, "termios_other.go"): os.path.join(repo, "tools/go/overlay/charm/termios_virelai.go"),
    os.path.join(module, "signals_unix.go"): os.path.join(repo, "tools/go/overlay/charm/signals_virelai.go"),
}
with open(out, "w") as f:
    json.dump({"Replace": replace}, f, sort_keys=True)
PY

cat >> "$MR/go.mod" <<EOF

require charm.land/bubbletea/v2 ${VERSION}
replace charm.land/bubbletea/v2 => $STAGE
EOF

OUT_DIR="$REPO/.build/go"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.ELF"

log "building ${TARGET_GOOS}/${TARGET_GOARCH} ./rss -> $OUT"
( cd "$MR" &&
    GOOS="$TARGET_GOOS" GOARCH="$TARGET_GOARCH" go build -mod=mod -overlay "$OVERLAY" \
        -ldflags "-s -w" -o "$OUT" ./rss )

# --- artifact guard: the produced ELF must be the guest target ------------
INFO="$(go version -m "$OUT" 2>/dev/null || true)"
printf '%s\n' "$INFO" | grep -q "GOOS=${TARGET_GOOS}" \
    || fail "artifact is not GOOS=${TARGET_GOOS}; refusing to ship a host build"
printf '%s\n' "$INFO" | grep -q "GOARCH=${TARGET_GOARCH}" \
    || fail "artifact is not GOARCH=${TARGET_GOARCH}"
printf '%s\n' "$INFO" | grep -q "CGO_ENABLED=0" \
    || fail "artifact was not built with CGO_ENABLED=0"
if printf '%s\n' "$INFO" | grep -qE 'GOOS=(darwin|linux|windows)'; then
    fail "artifact reports a non-guest GOOS"
fi

python3 - "$OUT" <<'PY'
import struct, sys

data = open(sys.argv[1], "rb").read(64)
assert data[:4] == b"\x7fELF", "not an ELF"
assert data[4] == 2, "not ELF64"
machine = struct.unpack_from("<H", data, 18)[0]
assert machine == 0xB7, "e_machine=%#x, want 0xB7 (EM_AARCH64)" % machine
print("build-rss: ELF64 AArch64 confirmed (e_machine=%#x)" % machine)
PY

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_INIT" ]; then
    fail "$SIZE bytes exceeds the 32 MiB initialized-image bound"
fi
log "size ok (<= ${MAX_INIT} B initialized file bound; ${MAX_MAP} B mapped bound enforced by the loader)"
log "target ok (${TARGET_GOOS}/${TARGET_GOARCH}, CGO_ENABLED=0, no darwin/linux target)"
