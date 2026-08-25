#!/usr/bin/env bash
#
# verify-live-resmon.sh -- M22 D10 (issue #333) class-B gate:
# RESMON.BIN — the resource monitor window — on real VZ hardware.
#
# Mechanism: boots the production image with the GPU (display), execs
# RESMON.BIN, waits for the app's `resmon: ready` marker (window open +
# 1 Hz refresh timer armed), then keeps the VM alive a few seconds for a
# screenshot. The class-B proof: the app opened its window through the
# toolkit and armed its refresh path live.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-resmon.sh
#
# Evidence saved under artifacts/: live-resmon-gate.txt,
# live-resmon-report.txt, live-resmon-run-*.txt, live-resmon-serial-*.log,
# resmon-screen-5s.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-resmon-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-resmon-report.txt)"

echo "=== verify-live-resmon: M22 D10 — RESMON.BIN resource monitor on VZ, $BOOTS boot(s) ==="

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
gate_begin live-resmon
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
exec RESMON.BIN
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$(art resmon-screen-5s)" \
        --script "$SCRIPT" \
        --script-expect "resmon: ready" \
        --timeout 45 \
        > "$(art live-resmon-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-resmon-serial-$tag.log)" || true
    local SER="$(art live-resmon-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 LOADED=0 OPEN=0 READY=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "exec: loaded RESMON.BIN size=" "$SER" && LOADED=1
        grep -qF -- "resmon: open" "$SER" && OPEN=1
        grep -qF -- "resmon: ready" "$SER" && READY=1
        # The shell stays responsive after the window is up.
        grep -qE "resmon: (failed to open window|ready)" "$SER" && ! grep -qF -- "[EXC] parking" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY alive=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY alive=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$LOADED" = 1 ] && [ "$OPEN" = 1 ] && [ "$READY" = 1 ] && [ "$REPLY" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-resmon: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-resmon-report.txt)"; exit 1; }
echo "=== verify-live-resmon: PASS — RESMON.BIN loaded, opened its resource-monitor window, and armed the refresh loop ($PASS/$BOOTS boot(s)). ==="
