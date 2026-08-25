#!/usr/bin/env bash
#
# verify-live-time.sh -- M22 D13 (issue #336) class-B gate:
# the `time <command>` timing wrapper on real VZ hardware.
#
# Mechanism: boots the production image and runs `time sysinfo`. The
# dashboard's map/allocator/storage walk is the heaviest synchronous
# monitor command (~250 ms observed on VZ), so the elapsed measurement
# MUST be nonzero. (`exec` is asynchronous on this kernel — `time exec X`
# measures only the load, ticks 0; there is no sleep/builtin that blocks.)
# Asserts both output lines (`real ...s` and `ticks N` with N >= 1).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-time.sh
#
# Evidence saved under artifacts/: live-time-gate.txt,
# live-time-report.txt, live-time-run-*.txt, live-time-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-time-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-time-report.txt)"

echo "=== verify-live-time: M22 D13 — time command wrapper on VZ, $BOOTS boot(s) ==="

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
gate_begin live-time
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
time sysinfo
echo rx-time-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-expect "rx-time-ok" \
        --timeout 90 \
        > "$(art live-time-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-time-serial-$tag.log)" || true
    local SER="$(art live-time-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 REAL_LINE=0 TICKS_NONZERO=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qE -- "^real +[0-9]+m[0-9]+s$" "$SER" && REAL_LINE=1
        # Nonzero elapsed ticks — only possible if the timer advanced
        # across the wrapped command's real execution.
        grep -qE -- "^ticks +[1-9][0-9]*$" "$SER" && TICKS_NONZERO=1
        grep -qF -- "rx-time-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER real-line=$REAL_LINE ticks-nonzero=$TICKS_NONZERO reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER real-line=$REAL_LINE ticks-nonzero=$TICKS_NONZERO reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$REAL_LINE" = 1 ] && [ "$TICKS_NONZERO" = 1 ] && [ "$REPLY" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-time: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-time-report.txt)"; exit 1; }
echo "=== verify-live-time: PASS — time measured nonzero elapsed ticks around a real ~250 ms sysinfo run ($PASS/$BOOTS boot(s)). ==="
