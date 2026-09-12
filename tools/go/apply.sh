#!/usr/bin/env bash
#
# apply.sh -- build/patch a GOOS=virelai gc toolchain fork (issue #1163).
#
# The fork is a COPY of a stock Go distribution (not a git checkout of
# golang/go — the go1.27.x release tags carry only the runtime+stdlib
# tree; the toolchain sources ship in the distribution). This script:
#   1. copies the stock GOROOT into $FORK_DIR (once),
#   2. copies the overlay files from tools/go/overlay/ into it,
#   3. applies the six small source edits (declarative, idempotent),
#   4. commits the patch as a git delta for reviewability.
#
# Re-running is safe: existing overlay/edit state is detected and kept.
#
# Usage:  bash tools/go/apply.sh [--fork-dir DIR]
#   --fork-dir DIR   fork location (default ../go-virelai next to the
#                    primary workspace checkout)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${FORK_DIR:-$(dirname "$REPO")/go-virelai}"
SRC_GOOS="virelai"
GO_VERSION="1.27.1"

if [ "${1:-}" = "--fork-dir" ]; then FORK_DIR="${2:?}"; shift 2; fi
[ $# -eq 0 ] || { echo "usage: bash tools/go/apply.sh [--fork-dir DIR]" >&2; exit 2; }

log() { printf 'apply: %s\n' "$*"; }

# --- 1. fresh copy of the stock distribution ---------------------------
if [ ! -d "$FORK_DIR" ]; then
    STOCK="${GOROOT_STOCK:-/opt/homebrew/Cellar/go/${GO_VERSION}/libexec}"
    [ -d "$STOCK/src/cmd/dist" ] || STOCK="$(go env GOROOT)"
    [ -d "$STOCK/src/cmd/dist" ] || { echo "apply: no stock GOROOT with src/cmd/dist found" >&2; exit 1; }
    log "copying stock distribution $STOCK -> $FORK_DIR"
    mkdir -p "$FORK_DIR"
    rsync -a --exclude bin --exclude pkg "$STOCK/" "$FORK_DIR/"
    ( cd "$FORK_DIR" && git init -q && git add -A &&
      git -c user.email=go-port@virelaios -c user.name=go-port \
        commit -qm "go${GO_VERSION} distribution baseline (pre-GOOS=${SRC_GOOS})" )
fi

F="$FORK_DIR/src"
[ -f "$F/runtime/time_nofake.go" ] || { echo "apply: $F does not look like a Go GOROOT src tree" >&2; exit 1; }

edits=0
have() { grep -qF "$2" "$1" 2>/dev/null; }

# --- 2. overlay files (new, GOOS-gated) --------------------------------
log "copying overlay files"
( cd "$REPO/tools/go/overlay" && find . -type f | while read -r f; do
    mkdir -p "$FORK_DIR/src/$(dirname "$f")"
    cp "$f" "$FORK_DIR/src/$f"
done )

# --- 3a. internal/syslist/syslist.go: KnownOS --------------------------
if ! have "$F/internal/syslist/syslist.go" '"virelai"'; then
    gsed -i 's/\t"wasip1":    true,/\t"wasip1":    true,\n\t"virelai":   true,/' "$F/internal/syslist/syslist.go"
    edits=$((edits+1)); log "patched internal/syslist/syslist.go (KnownOS)"
fi

# --- 3b. cmd/dist/build.go: okgoos + cgoEnabled ------------------------
if ! have "$F/cmd/dist/build.go" '"virelai",'; then
    gsed -i 's/^\t"wasip1",$/\t"wasip1",\n\t"virelai",/' "$F/cmd/dist/build.go"
    edits=$((edits+1)); log "patched cmd/dist/build.go (okgoos)"
fi
if ! have "$F/cmd/dist/build.go" '"virelai/arm64"'; then
    gsed -i 's/^\t"wasip1\/wasm":     false,$/\t"wasip1\/wasm":     false,\n\t"virelai\/arm64":  false,/' "$F/cmd/dist/build.go"
    edits=$((edits+1)); log "patched cmd/dist/build.go (cgoEnabled)"
fi

# --- 3c. cmd/internal/objabi/head.go: virelai -> ELF (Hlinux) ----------
if ! have "$F/cmd/internal/objabi/head.go" 'case "virelai":'; then
    gsed -i 's/^\tcase "wasip1":$/\tcase "virelai":\n\t\t*h = Hlinux\n\tcase "wasip1":/' "$F/cmd/internal/objabi/head.go"
    edits=$((edits+1)); log "patched cmd/internal/objabi/head.go (HeadType)"
fi

# --- 3d. runtime/mem_sbrk.go: the sbrk memory platform -----------------
if ! head -6 "$F/runtime/mem_sbrk.go" | grep -q virelai; then
    gsed -i 's#^//go:build plan9 || wasm$#//go:build plan9 || wasm || virelai#' "$F/runtime/mem_sbrk.go"
    edits=$((edits+1)); log "patched runtime/mem_sbrk.go (build tag)"
fi

# --- 3e. runtime/lock_sema.go: spinning semaphores (no OS primitives) --
if ! head -6 "$F/runtime/lock_sema.go" | grep -q virelai; then
    gsed -i 's#^//go:build aix || darwin || netbsd || openbsd || plan9 || solaris || windows$#//go:build aix || darwin || netbsd || openbsd || plan9 || solaris || windows || virelai#' "$F/runtime/lock_sema.go"
    edits=$((edits+1)); log "patched runtime/lock_sema.go (build tag)"
fi

# --- 3f. runtime/proc.go: sysmon off for the single-thread phase -------
if ! have "$F/runtime/proc.go" 'GOARCH != "wasm" && GOOS != "virelai"'; then
    gsed -i 's|^const haveSysmon = GOARCH != "wasm"$|const haveSysmon = GOARCH != "wasm" \&\& GOOS != "virelai" // issue #1163: phase 0a single-thread; remove with slots 72/73|' "$F/runtime/proc.go"
    edits=$((edits+1)); log "patched runtime/proc.go (haveSysmon)"
fi

# --- 3f2. runtime/tls_arm64.h: the virelai TLS case --------------------
# Pure-Go arm64 keeps g in R28 (load_g/save_g return immediately for
# non-cgo), so the MRS below never executes — but the file must assemble.
# Map virelai onto the linux-style TPIDR_EL0 macro.
if ! have "$F/runtime/tls_arm64.h" 'GOOS_virelai'; then
    python3 - "$F/runtime/tls_arm64.h" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "GOOS_virelai" not in s:
    anchor = "#ifdef GOOS_linux\n#define TLS_linux\n#endif"
    assert anchor in s
    s = s.replace(anchor, "#ifdef GOOS_virelai\n#define TLS_linux\n#endif\n" + anchor, 1)
    open(p, "w").write(s)
PYEOF
    edits=$((edits+1)); log "patched runtime/tls_arm64.h (virelai -> TPIDR_EL0, unused)"
fi

# --- 3f3. runtime/proc.go: gate the remaining thread-creation paths ----
# Phase 0a has no kernel thread_create (slot 72, phase 0b): the template
# thread, startTheWorld's spare-M handoff, and startm's new-M fallback all
# funnel into newosproc, which throws on virelai. One const carries the
# fork delta (tools/go/patch_proc.py); it disappears with slot 72/73.
if ! have "$F/runtime/proc.go" 'canCreateM'; then
    python3 "$REPO/tools/go/patch_proc.py" "$F/runtime/proc.go"
    edits=$((edits+1)); log "patched runtime/proc.go (canCreateM thread gates)"
fi

# --- 3g. exclude virelai from generic-tag files it must not match ------
# Appends "&& !virelai" to the //go:build line; each reason inline.
vir_exclude() {  # <file> <reason>
    if ! head -8 "$F/runtime/$1" | grep -q virelai; then
        gsed -i '0,/^\/\/go:build /s#^//go:build \(.*\)$#//go:build \1 \&\& !virelai#' "$F/runtime/$1"
        edits=$((edits+1)); log "patched runtime/$1 (exclude virelai: $2)"
    fi
}
# mem_nonsbrk.go declares isSbrkPlatform=false for everything non-sbrk.
vir_exclude mem_nonsbrk.go "sbrk platform"
# stubs2.go declares exit/write1/exitThread/usleep (+read/open/madvise)
# bodyless — os_virelai.go provides the ones it needs.
vir_exclude stubs2.go "GOOS-level exit/write1/exitThread"
# stubs3.go + timestub2.go declare nanotime1/walltime as gojs
# host-imports (GOOS=js machinery) — virelai provides its own.
vir_exclude stubs3.go "js nanotime1 wasmimport"
vir_exclude timestub2.go "js walltime wasmimport"

# --- 3g. internal/platform/zosarch.go: List + distInfo rows ------------
if ! have "$F/internal/platform/zosarch.go" '{"virelai", "arm64"}'; then
    gsed -i 's|^\t{"wasip1", "wasm"},$|\t{"virelai", "arm64"},\n\t{"wasip1", "wasm"},|' "$F/internal/platform/zosarch.go"
    gsed -i 's|^\t{"wasip1", "wasm"}:     {},$|\t{"virelai", "arm64"}:   {},\n\t{"wasip1", "wasm"}:     {},|' "$F/internal/platform/zosarch.go"
    edits=$((edits+1)); log "patched internal/platform/zosarch.go"
fi

# --- 4. commit the delta ----------------------------------------------
if [ "$edits" -gt 0 ]; then
    ( cd "$FORK_DIR" && git add -A &&
      git -c user.email=go-port@virelaios -c user.name=go-port \
        commit -qm "GOOS=virelai: overlay + wiring (issue #1163 phase 0a)" )
fi
log "fork ready at $FORK_DIR ($edits new edits)"
log "next: GOROOT_BOOTSTRAP=<stock go> bash $FORK_DIR/src/make.bash"
log "      GOOS=$SRC_GOOS GOARCH=arm64 bash $FORK_DIR/src/make.bash"
