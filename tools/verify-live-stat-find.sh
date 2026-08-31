#!/usr/bin/env bash
#
# verify-live-stat-find.sh -- M22 D8 (issue #331) class-B gate:
# `stat` + `find` filesystem inspection on real VZ hardware.
#
# Mechanism: boots the production image, runs `stat KERNEL.BIN` (ESP window
# lookup), `stat EFI` (directory type), and a bounded recursive
# `find / -name *.BIN`, then asserts the metadata shape (File/Size/Type/
# Cluster) and that find lists the known root binaries.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-stat-find.sh
#
# Evidence saved under artifacts/: live-stat-find-gate.txt,
# live-stat-find-report.txt, live-stat-find-run-*.txt,
# live-stat-find-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-stat-find-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-stat-find-report.txt)"

echo "=== verify-live-stat-find: M22 D8 — stat + find filesystem inspection on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-stat-find
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
stat KERNEL.BIN
stat /KERNEL.BIN
stat EFI
find / -name "*.BIN"
echo rx-statfind-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-expect "rx-statfind-ok" \
        --timeout 60 \
        > "$(art live-stat-find-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-stat-find-serial-$tag.log)" || true
    local SER="$(art live-stat-find-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 STAT_FILE=0 STAT_SIZE=0 STAT_TYPE=0 STAT_DIR=0 STAT_CLUSTER=0 FIND_KERNEL=0 FIND_COUNT=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "  File:  KERNEL.BIN" "$SER" && STAT_FILE=1
        grep -qF -- "  File:  KERNEL.BIN" "$SER" && STAT_FILE=1
        grep -A3 -- "  File:  KERNEL.BIN" "$SER" | grep -qF -- "  Size:" && STAT_SIZE=1
        grep -A5 -- "  File:  KERNEL.BIN" "$SER" | grep -qF -- "regular file" && STAT_TYPE=1
        grep -A5 -- "  File:  EFI" "$SER" | grep -qF -- "directory" && STAT_DIR=1
        grep -qF -- "  Cluster: " "$SER" && STAT_CLUSTER=1
        grep -qF -- "/KERNEL.BIN" "$SER" && FIND_KERNEL=1
        FIND_COUNT=$(grep -acE "^/[A-Za-z0-9_]+\.BIN$" "$SER" 2>/dev/null || true)
        grep -qF -- "rx-statfind-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER stat-file=$STAT_FILE stat-size=$STAT_SIZE stat-type=$STAT_TYPE stat-dir=$STAT_DIR stat-cluster=$STAT_CLUSTER find-kernel=$FIND_KERNEL find-matches=$FIND_COUNT reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER stat-file=$STAT_FILE stat-size=$STAT_SIZE stat-type=$STAT_TYPE stat-dir=$STAT_DIR stat-cluster=$STAT_CLUSTER find-kernel=$FIND_KERNEL find-matches=$FIND_COUNT reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$STAT_FILE" = 1 ] && [ "$STAT_SIZE" = 1 ] \
    && [ "$STAT_TYPE" = 1 ] && [ "$STAT_DIR" = 1 ] && [ "$STAT_CLUSTER" = 1 ] \
    && [ "$FIND_KERNEL" = 1 ] && [ "$FIND_COUNT" -ge 2 ] && [ "$REPLY" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-stat-find: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-stat-find-report.txt)"; exit 1; }
echo "=== verify-live-stat-find: PASS — stat reported file metadata (size/type/cluster), stat resolved a directory entry, and find walked / recursively listing *.BIN matches ($PASS/$BOOTS boot(s)). ==="
