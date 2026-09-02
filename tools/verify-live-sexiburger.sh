#!/usr/bin/env bash
#
# verify-live-sexiburger.sh — Milestone 19 class-B live gate: Sexiburger God Menu on real VZ.
#
# Launches SEXIBURG.BIN, sends Ctrl+B chord to summon the menu,
# and captures the live screen output.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-sexiburger-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-sexiburger-report.txt)"

echo "=== verify-live-sexiburger: Milestone 19 Sexiburger God Menu on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build sexiburg
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ---
gate_begin live-sexiburger
gate_seed_share
echo "run dir: $RUN_DIR"

SCRIPT="$RUN_DIR/script.txt"
cat > "$SCRIPT" <<'EOF'
exec SEXIBURG.BIN
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

cat > "$RUN_DIR/script2.txt" <<'EOF'
echo sexiburger-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/gpu-screen-*

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$RUN_DIR/gpu-screen-$tag" \
        --via-virtio \
        --script "$SCRIPT" \
        --script-after "$STATIC_EXIT_LINE" \
        --input-chords "ctrl-b" \
        --input-chords-after "sexiburger: ready" \
        --screenshot-after "sexiburger: ready" \
        --script2 "$RUN_DIR/script2.txt" \
        --script2-after "timer heartbeat ticks=15" \
        --script-expect "sexiburger-live-ok" \
        --timeout 45 \
        > "$(art live-sexiburger-run-$tag.txt)" 2>&1
    local RC=$?
    set -e

    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-sexiburger-serial-$tag.log)" || true
    cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
    local SER="$(art live-sexiburger-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 SEXIBURG_READY=0 DONE=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "sexiburger: ready" "$SER" && SEXIBURG_READY=1
        grep -qF -- "sexiburger-live-ok" "$SER" && DONE=1
    fi

    echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER sexiburg-ready=$SEXIBURG_READY done=$DONE"
    echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER sexiburg-ready=$SEXIBURG_READY done=$DONE" >> "$REPORT"

    if [ $RC -ne 0 ] || [ $BANNER -ne 1 ] || [ $SEXIBURG_READY -ne 1 ] || [ $DONE -ne 1 ]; then
        echo "FAIL: $tag failed live assertions (rc=$RC banner=$BANNER ready=$SEXIBURG_READY done=$DONE)" >&2
        return 1
    fi
}

rm -f "$REPORT"
touch "$REPORT"

for b in $(seq 1 "$BOOTS"); do
    tag="boot-$b"
    echo "--- boot $b/$BOOTS ---"
    run_one "$tag"
done

echo "verify-live-sexiburger: PASS ($BOOTS/$BOOTS boots ok)"
