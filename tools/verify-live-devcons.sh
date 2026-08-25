#!/usr/bin/env bash
#
# verify-live-devcons.sh -- M22 D14 (issue #337) class-B gate:
# DEVCONS.BIN — the developer console — on real VZ hardware.
#
# Mechanism: boots the production image with the GPU (display), execs
# DEVCONS.BIN, waits for the app's `devcons: ready` marker (split-screen
# window open + log-poll timer armed), then keeps the VM alive a few
# seconds for a screenshot of the split layout.
#
# Honest scope note: the issue's full gate shape (typing a command at the
# in-window prompt and watching it land in the log pane) needs keyboard
# delivery into the windowed app, which is blocked upstream by issue #179
# (synthesized keyboard seam reports events=0). This gate proves the app's
# live window path; the typed-input proof lands with #179's fix.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-devcons.sh
#
# Evidence saved under artifacts/: live-devcons-gate.txt,
# live-devcons-report.txt, live-devcons-run-*.txt, live-devcons-serial-*.log,
# devcons-screen-5s.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-devcons-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-devcons-report.txt)"

echo "=== verify-live-devcons: M22 D14 — DEVCONS.BIN developer console on VZ, $BOOTS boot(s) ==="

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
gate_begin live-devcons
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
exec DEVCONS.BIN
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$(art devcons-screen-5s)" \
        --script "$SCRIPT" \
        --script-expect "devcons: ready" \
        --timeout 45 \
        > "$(art live-devcons-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-devcons-serial-$tag.log)" || true
    local SER="$(art live-devcons-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 LOADED=0 OPEN=0 READY=0 ALIVE=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "exec: loaded DEVCONS.BIN size=" "$SER" && LOADED=1
        grep -qF -- "devcons: open" "$SER" && OPEN=1
        grep -qF -- "devcons: ready" "$SER" && READY=1
        grep -qF -- "[EXC] parking" "$SER" || ALIVE=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY alive=$ALIVE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY alive=$ALIVE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$LOADED" = 1 ] && [ "$OPEN" = 1 ] && [ "$READY" = 1 ] && [ "$ALIVE" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-devcons: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-devcons-report.txt)"; exit 1; }
echo "=== verify-live-devcons: PASS — DEVCONS.BIN loaded and opened its split-screen console window live on VZ ($PASS/$BOOTS boot(s)); typed-input proof deferred to issue #179. ==="
