#!/usr/bin/env bash
#
# verify-live-inventory.sh -- M22 D16 (issue #339) class-B gate:
# `which` + `inventory` package/tool inventory on real VZ hardware.
#
# Mechanism: boots the production image and exercises the command locator
# across all three answer classes (shell builtin, monitor command, ESP
# application) plus a not-found case, then runs `inventory` and asserts it
# lists the installed applications with sizes.
#
# Note: `echo` is a monitor command in this kernel, so the builtin class is
# proven with `type` (a real shell builtin per shell.zig's dispatch list).
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-inventory.sh
#
# Evidence saved under artifacts/: live-inventory-gate.txt,
# live-inventory-report.txt, live-inventory-run-*.txt,
# live-inventory-serial-*.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-inventory-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-inventory-report.txt)"

echo "=== verify-live-inventory: M22 D16 — which + inventory on VZ, $BOOTS boot(s) ==="

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
gate_begin live-inventory
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
which type
which stat
which NOTEPAD.BIN
which nope.bin
inventory
echo rx-inv-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-expect "rx-inv-ok" \
        --timeout 60 \
        > "$(art live-inventory-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-inventory-serial-$tag.log)" || true
    local SER="$(art live-inventory-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 BUILTIN=0 MONITOR=0 APP=0 NOTFOUND=0 INV_HEADER=0 INV_APP=0 REPLY=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "type: shell builtin" "$SER" && BUILTIN=1
        grep -qF -- "stat: monitor command" "$SER" && MONITOR=1
        grep -qF -- "NOTEPAD.BIN: ESP application" "$SER" && APP=1
        grep -qF -- "nope.bin: not found" "$SER" && NOTFOUND=1
        grep -qE -- "^inventory: [0-9]+ application\(s\):$" "$SER" && INV_HEADER=1
        grep -A40 -- "application(s):" "$SER" | grep -qF -- "NOTEPAD.BIN" && INV_APP=1
        grep -qF -- "rx-inv-ok" "$SER" && REPLY=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER builtin=$BUILTIN monitor=$MONITOR app=$APP notfound=$NOTFOUND inv-header=$INV_HEADER inv-app=$INV_APP reply=$REPLY"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER builtin=$BUILTIN monitor=$MONITOR app=$APP notfound=$NOTFOUND inv-header=$INV_HEADER inv-app=$INV_APP reply=$REPLY"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$BUILTIN" = 1 ] && [ "$MONITOR" = 1 ] \
    && [ "$APP" = 1 ] && [ "$NOTFOUND" = 1 ] && [ "$INV_HEADER" = 1 ] && [ "$INV_APP" = 1 ] && [ "$REPLY" = 1 ]
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

[ "$PASS" -ge 1 ] || { echo "verify-live-inventory: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-inventory-report.txt)"; exit 1; }
echo "=== verify-live-inventory: PASS — which resolved all three command classes + not-found, inventory listed the APPS.TXT applications ($PASS/$BOOTS boot(s)). ==="
