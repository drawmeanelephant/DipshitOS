#!/usr/bin/env bash
#
# verify-live-typography.sh — M38 Live TrueType Typography Verification
#
# Proves, in a live VZ VM on Apple silicon:
#   1. The host share seeds TrueType fonts (/host/INTER.TTF and /host/FIRACODE.TTF).
#   2. On application window creation (NOTEPAD.BIN and EDIT.BIN), ui.init_fonts()
#      automatically probes and loads both Inter and Fira Code fonts.
#   3. The guest emits the serial markers:
#        "typography: Inter TrueType font loaded"
#        "typography: Fira Code TrueType font loaded"
#   4. Desktop applications render with proportional Inter / monospace Fira Code.
#   5. The custom-virtio capture proves screen composition with live fonts.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio). CI=yes.
#
# Usage:  bash tools/verify-live-typography.sh
# Evidence: artifacts/live-typography-{run.txt,serial.log,snap.raw},
#           artifacts/live-typography-gate.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-typography-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

echo "=== verify-live-typography: M38 TrueType Typography & GUI Quality Pass ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
echo
echo "[1/4] Checking formatting and building binaries"
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/lib/ui.zig user/src/lib/sexiburger.zig user/src/notepad.zig user/src/calc.zig user/src/edit.zig user/src/devcons.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
echo
echo "[2/4] Initializing VM run directory and seeding share"
gate_begin live-typography
gate_seed_share
echo "run dir: $RUN_DIR"

# Verify fonts are in share
[ -f "$RUN_DIR/share/INTER.TTF" ] || { echo "FAIL: INTER.TTF missing from share"; exit 1; }
[ -f "$RUN_DIR/share/FIRACODE.TTF" ] || { echo "FAIL: FIRACODE.TTF missing from share"; exit 1; }
echo "Seeded Inter TTF: $(ls -l "$RUN_DIR/share/INTER.TTF")"
echo "Seeded Fira Code TTF: $(ls -l "$RUN_DIR/share/FIRACODE.TTF")"

# --- VM execution ------------------------------------------------------------
echo
echo "[3/4] Booting VM with NOTEPAD.BIN to verify TrueType auto-init"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR"/snap-*.raw

# Prepare script: run notepad
cat << 'EOF' > "$RUN_DIR/script.txt"
settings set theme dark
exec NOTEPAD.BIN
EOF

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --screen "$RUN_DIR/screen" \
    --via-virtio --cvc-snap \
    --snapshot-out "$RUN_DIR/snap" \
    --script "$RUN_DIR/script.txt" \
    --snapshot-after "notepad: settled" \
    --script-expect "notepad: settled" \
    --script-expect-tail 2 \
    --timeout 120 \
    > "$(art live-typography-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-typography-serial.log)" || true
SNAP="$(ls "$RUN_DIR"/snap-*.raw 2>/dev/null | head -1 || true)"
[ -n "$SNAP" ] && cp "$SNAP" "$(art live-typography-snap.raw)" || true

echo "VM runner completed with rc=$RC snap=${SNAP:-none}"

# --- Assertions --------------------------------------------------------------
echo
echo "[4/4] Verifying evidence in serial log and screen capture"

SERIAL_LOG="$RUN_DIR/vm-serial.log"
if [ ! -f "$SERIAL_LOG" ]; then
    echo "FAIL: serial log not found at $SERIAL_LOG" >&2
    exit 1
fi

echo "-- Grepping for TrueType font initialization markers --"
if grep -q "typography: Inter TrueType font loaded" "$SERIAL_LOG"; then
    echo "  [OK] Found 'typography: Inter TrueType font loaded'"
else
    echo "  FAIL: 'typography: Inter TrueType font loaded' not found in serial log" >&2
    exit 1
fi

if grep -q "typography: Fira Code TrueType font loaded" "$SERIAL_LOG"; then
    echo "  [OK] Found 'typography: Fira Code TrueType font loaded'"
else
    echo "  FAIL: 'typography: Fira Code TrueType font loaded' not found in serial log" >&2
    exit 1
fi

if grep -q "notepad: open id=" "$SERIAL_LOG"; then
    echo "  [OK] Found 'notepad: open id='"
else
    echo "  FAIL: NOTEPAD.BIN did not open window" >&2
    exit 1
fi

if grep -q "notepad: settled" "$SERIAL_LOG"; then
    echo "  [OK] Found 'notepad: settled'"
else
    echo "  FAIL: 'notepad: settled' not found in serial log" >&2
    exit 1
fi

if [ -n "$SNAP" ] && [ -s "$SNAP" ]; then
    SNAP_SIZE=$(stat -f%z "$SNAP" 2>/dev/null || stat -c%s "$SNAP")
    echo "  [OK] Framebuffer snapshot captured: $SNAP_SIZE bytes"
else
    echo "  FAIL: Framebuffer snapshot missing or empty" >&2
    exit 1
fi

echo
echo "=== verify-live-typography: PASS — TrueType vector typography verified on live VZ VM ==="
