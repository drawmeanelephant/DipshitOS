#!/usr/bin/env bash
#
# verify-live-dmesg.sh -- M22 D12 (issue #335) class-B gate:
# the `dmesg` system log viewer on real VZ hardware.
#
# Mechanism: boots the production image, echoes a unique marker, then runs
# `dmesg`. The serial ring holds the marker from the echo output; the dmesg
# dump must contain it a SECOND time — the round trip through the ring
# buffer proves the viewer reads real console history.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-dmesg.sh
#
# Evidence saved under artifacts/: live-dmesg-gate.txt,
# live-dmesg-report.txt, live-dmesg-run-*.txt, live-dmesg-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-dmesg-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-dmesg-report.txt)"

echo "=== verify-live-dmesg: M22 D12 — dmesg system log viewer on VZ, $BOOTS boot(s) ==="

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
gate_begin live-dmesg
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
version
echo dmesg-marker-7777
dmesg
echo rx-dmesg-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-expect "rx-dmesg-ok" \
        --timeout 60 \
        > "$(art live-dmesg-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-dmesg-serial-$tag.log)" || true
    local SER="$(art live-dmesg-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 MARKER_COUNT=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        # Once from the echo output, once again inside the dmesg ring dump.
        MARKER_COUNT=$(grep -acF -- "dmesg-marker-7777" "$SER" 2>/dev/null || true)
        grep -qF -- "rx-dmesg-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER marker-count=$MARKER_COUNT reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER marker-count=$MARKER_COUNT reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$MARKER_COUNT" -ge 2 ] && [ "$REPLY" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-dmesg: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-dmesg-report.txt)"; exit 1; }
echo "=== verify-live-dmesg: PASS — the echoed marker reappeared inside the dmesg ring dump (console history observed end to end) ($PASS/$BOOTS boot(s)). ==="
