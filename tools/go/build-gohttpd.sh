#!/usr/bin/env bash
#
# build-gohttpd.sh -- build the M71l (#1571) Go replacement for the Zig
# HTTPD.BIN in-guest HTTP/1.1 publisher (user/go/httpd) with the GOOS=virelai
# fork toolchain. Output: .build/go/GOHTTPD.ELF
#
# Usage: bash tools/go/build-gohttpd.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="httpd"
NAME="${GO_BUILD_NAME:-GOHTTPD}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-gohttpd: %s\n' "$*"; }

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
need = 0x908
if slack < need:
    sys.exit("build-gohttpd: writable segment memsz %#x leaves only %#x bytes of "
             "page slack; the kernel's argv+envp protection needs >= %#x or the "
             "runtime's first mmap is refused (grow user/go/httpd argvEnvpGuard)"
             % (mem, slack, need))
print("build-gohttpd: argv+envp slack ok (memsz %#x, slack %#x bytes)" % (mem, slack))
PY
