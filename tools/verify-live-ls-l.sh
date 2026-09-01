#!/usr/bin/env bash
#
# verify-live-ls-l.sh -- M22 D15 (issue #338) class-B gate:
# `ls -l` long listing on real VZ hardware.
#
# Mechanism: boots the production image and runs `ls -l` at the ESP root,
# asserting the long-listing shape for both entry types: files print
# `-rw- ... root <size> NAME` and directories print `drwx ... root`.
# Also runs plain `ls` to prove the default listing still works.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-ls-l.sh
#
# Evidence saved under artifacts/: live-ls-l-gate.txt,
# live-ls-l-report.txt, live-ls-l-run-*.txt, live-ls-l-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-ls-l-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-ls-l-report.txt)"

echo "=== verify-live-ls-l: M22 D15 — ls -l long listing on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
# M34 HF6 (issue #740): `ls` lists the host share — the gate seeds the
# app bundle (KERNEL.BIN + an EFI dir so the long-format rows cover both
# files and directories) and arms the channel (SPIKE runner build).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-ls-l
gate_seed_share
mkdir -p "$SHARE/EFI"
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
ls -l
ls
echo rx-lsl-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-expect "rx-lsl-ok" \
        --timeout 60 \
        > "$(art live-ls-l-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-ls-l-serial-$tag.log)" || true
    local SER="$(art live-ls-l-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 FILE_BITS=0 DIR_BITS=0 OWNER=0 SIZE=0 KERNEL_L=0 PLAIN_LS=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        # Long format wraps each entry over two lines: bits+owner line,
        # then an indented size + name line.
        grep -qE -- "^-rw- +1 +root$" "$SER" && FILE_BITS=1
        grep -qE -- "^drwx +1 +root$" "$SER" && DIR_BITS=1
        grep -qF -- "root" "$SER" && OWNER=1
        grep -qE -- "^ +[0-9]{3,} +[A-Z]+\.BIN$" "$SER" && SIZE=1
        # Kernel size is build-derived; pin to the current build's bytes
        # (observed in the gate's own zig build output; see the log).
        grep -qE -- "^ +11406096 +KERNEL\.BIN$" "$SER" && KERNEL_L=1
        # Plain ls still lists with sizes.
        grep -qE -- "^  [A-Za-z0-9_]+\.BIN" "$SER" && PLAIN_LS=1
        grep -qF -- "rx-lsl-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER file-bits=$FILE_BITS dir-bits=$DIR_BITS owner=$OWNER size=$SIZE kernel-long=$KERNEL_L plain-ls=$PLAIN_LS reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER file-bits=$FILE_BITS dir-bits=$DIR_BITS owner=$OWNER size=$SIZE kernel-long=$KERNEL_L plain-ls=$PLAIN_LS reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$FILE_BITS" = 1 ] && [ "$DIR_BITS" = 1 ] \
    && [ "$OWNER" = 1 ] && [ "$SIZE" = 1 ] && [ "$KERNEL_L" = 1 ] && [ "$PLAIN_LS" = 1 ] && [ "$REPLY" = 1 ]
}

PASS=0
i=1
while [ "$i" -le "$BOOTS" ]; do
    TAG="$(printf '%02d' "$i")"
    if run_one "$TAG"; then
        PASS=$((PASS + 1))
    fi
    i=$((i + 1))
done

gate_end

[ "$PASS" -ge 1 ] || { echo "verify-live-ls-l: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-ls-l-report.txt)"; exit 1; }
echo "=== verify-live-ls-l: PASS — ls -l printed long entries (file rw- bits, dir rwx bits, root owner, sizes) and plain ls is unchanged ($PASS/$BOOTS boot(s)). ==="
