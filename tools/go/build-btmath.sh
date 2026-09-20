#!/usr/bin/env bash
#
# build-btmath.sh -- build the Bubble Tea userland app (user/go/btmath) with the
# GOOS=virelai fork toolchain. Output: .build/go/BTMATH.ELF
#
# Usage: bash tools/go/build-btmath.sh
#
# This is the first guest build in the tree with a THIRD-PARTY dependency.
# Bubble Tea (charm.land/bubbletea/v2) and its transitive requirements live in
# user/go/vendor, which GOPATH-mode resolution finds for the importing package;
# no network and no module cache are involved. Upstream Bubble Tea defines its
# terminal hooks only for the OSes it ships (x/sys + termios behind build tags),
# so the vendored copy carries two `//go:build virelai` files
# (tty_virelai.go, signals_virelai.go) that supply the four symbols that would
# otherwise be missing: initInput, listenForResize, suspendProcess,
# suspendSupported. See user/go/btmath/README.md.
#
# SIZE: a GOOS=virelai Go image is a gap-layout static ELF, so the kernel
# STREAMS its segments and bounds it by exec_image_max (32 MiB) rather than by
# the 2 MiB whole-file staging buffer (kernel/src/exec.zig, M70c-K / #1504).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="btmath"
NAME="${GO_BUILD_NAME:-BTMATH}"
MAX_BYTES=33554432 # kernel/src/exec.zig exec_image_max

log() { printf 'build-btmath: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

if [ ! -d "$REPO/user/go/vendor/charm.land/bubbletea/v2" ]; then
    log "user/go/vendor is missing the vendored Bubble Tea tree"
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
# -tags virelaitoolchain: excludes crypto/internal/fips140/drbg's
# `var memory entropy.ScratchBuffer` (exactly 33,554,432 B of .noptrbss), which
# a Bubble Tea closure reaches through crypto/rand. kernel/src/elf.zig sums
# every PT_LOAD memsz against load_max (32 MiB), so that one demand-backed
# object alone pushes the image to 37,269,084 B and the loader refuses it with
# segment_too_large. With the tag: 3,702,444 B. tools/go/apply.sh section 3g8
# records the same object hitting cmd/compile; the tag is normally scoped to
# cmd/compile and cmd/link because a guest must keep a working crypto/rand.
# btmath calls no crypto, so the DRBG stub (entropy_virelai.go) is dead weight
# here - but it PANICS if ever reached, by design. Remove the tag once the
# loader stops charging address space (see user/go/btmath/README.md).
( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -tags virelaitoolchain -o "$OUT" -ldflags "-s -w" "virelai/$DIR" )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds exec_image_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
