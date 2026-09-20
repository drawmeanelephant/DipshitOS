#!/usr/bin/env bash
#
# build-gosh.sh -- build the M68a Go shell (user/go/sh) with the GOOS=virelai
# fork toolchain, the same way tools/go/build-goterm.sh builds the M58c
# terminal. Output: .build/go/GOSH.ELF
#
# Usage: bash tools/go/build-gosh.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="sh"
NAME="${GO_BUILD_NAME:-GOSH}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-gosh: %s\n' "$*"; }

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

# The kernel packs argv+envp (0x900 bytes) into the writable segment's tail
# and protects it against the sbrk break (mmap_collides, issue #1214); the
# runtime's break starts at the page-rounded bss end, so the bss must end
# at least 0x900 bytes below the segment's page end or mallocinit dies on
# its first mmap. Assert it from the linked ELF, naming the padding var.
python3 - "$OUT" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
e_phoff, = struct.unpack_from("<Q", d, 0x20)
e_phentsize, e_phnum = struct.unpack_from("<HH", d, 0x36)
mem = 0
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type, p_flags = struct.unpack_from("<II", d, off)
    if p_type == 1 and (p_flags & 2):  # PT_LOAD, W — the writable segment
        mem = struct.unpack_from("<Q", d, off + 40)[0]  # p_memsz
slack = (-mem) % 4096
need = 0x908  # the packed block (0x900) plus its 8-byte alignment step
if slack < need:
    sys.exit("build-gosh: writable segment memsz %#x leaves only %#x bytes of "
             "page slack; the kernel's argv+envp protection needs >= %#x or the "
             "runtime's first mmap is refused (grow user/go/sh argvEnvpGuard)"
             % (mem, slack, need))
print("build-gosh: argv+envp slack ok (memsz %#x, slack %#x bytes)" % (mem, slack))
PY

# Issue #1503: a hand-built ELF with no stamp is indistinguishable from a
# leftover from another branch. Stamp source+elf hashes so class-B setup
# can refuse a mismatch by name instead of booting it.
case "$NAME" in
    GOSH|GOSSHD) ENSURE_GUEST_ELF_ROOT="$REPO" bash "$REPO/tools/go/ensure-guest-elf.sh" stamp "$NAME" "$OUT" ;;
esac
