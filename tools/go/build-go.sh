#!/usr/bin/env bash
#
# build-go.sh -- build GOOS=virelai programs with the fork toolchain
# (issue #1163). Runs the two make.bash passes on first use (host toolchain
# for go generate plumbing, then the virelai/arm64 cross toolchain), then
# links the named program as a static ET_EXEC at the kernel's fixed text
# aperture (0x400000), DWARF+symtab stripped to fit the 1 MiB staging
# bound (kernel exec.zig exec_program_max).
#
# Usage: bash tools/go/build-go.sh [program.go ...]
#   Builds tools/go/hello.go by default. Output: <program>.ELF next to the
#   source, or into $GO_BUILD_OUT when set (the gate copies from there).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
BOOTSTRAP="${GOROOT_STOCK:-/opt/homebrew/Cellar/go/1.27.1/libexec}"

log() { printf 'build-go: %s\n' "$*"; }

[ -d "$FORK_DIR/src/runtime" ] || bash "$REPO/tools/go/apply.sh" --fork-dir "$FORK_DIR"

# Pass 1: host toolchain (built from the PATCHED tree, so bin/go already
# knows GOOS=virelai and its cross tool binaries target arm64). Programs
# that import runtime only need this pass — packages compile on demand
# into the build cache. Pass 2 (a full `GOOS=virelai make.bash` std
# install) is phase 2: it needs the syscall/os port layer (the wasip1
# mirror) and is opt-in via GOVIRELAI_STD=1.
if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "building host toolchain (make.bash pass 1)"
    ( cd "$FORK_DIR/src" && GOROOT_BOOTSTRAP="$BOOTSTRAP" ./make.bash ) >&2
fi

if [ "${GOVIRELAI_STD:-0}" = "1" ]; then
    log "installing full std for virelai/arm64 (phase 2: needs the syscall/os port)"
    ( cd "$FORK_DIR/src" && GOROOT_BOOTSTRAP="$BOOTSTRAP" GOOS=virelai GOARCH=arm64 ./make.bash ) >&2
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local   # never silently swap back to a stock toolchain
export GOFLAGS=
export GO111MODULE=off
export GOPATH="${TMPDIR:-/tmp}/go-virelai-gopath"
export CGO_ENABLED=0

mkdir -p "$GOPATH"
out_dir="${GO_BUILD_OUT:-$REPO/.build/go}"
mkdir -p "$out_dir"
rc=0
for prog in "${@:-$REPO/tools/go/hello.go}"; do
    base="$(basename "${prog%.go}")"
    out="$out_dir/${GO_BUILD_NAME:-$base}.ELF"
    log "building $prog -> $out"
    GOOS=virelai GOARCH=arm64 go build -o "$out" \
        ${GO_LDFLAGS:--ldflags "-w"} "$prog" || rc=1
done
exit "$rc"
