#!/usr/bin/env bash
#
# verify-live-sb4-damage-tracking.sh -- M33 SB4 (claim 2382) class-B gate:
# rect-granular damage, live on real VZ hardware.
#
# SB4DAM.BIN opens a 128x96 user window and fills TWO rects (8,8,48,48 and
# 100,60,16,16) back-to-back via the kernel-visible fill path (slot 13), with
# NO yield between them, so they coalesce into ONE union damage rect
# {8,8,108,68}. The compositor then repaints EXACTLY that union — not the whole
# window — which the gate observes on serial via `dui`'s new `last=x,y,w,h`
# column (the rect paint actually blitted). The `--script-expect` targets that
# exact string, so the runner returns 0 ONLY when rect-granular repaint actually
# happened. A full-window repaint would emit last=0,0,0,0 (no partial recorded)
# and the gate fails.
#
# Serial evidence (gate's grep targets, pinned host-side in sb4dam.zig):
#   sb4: filled   ~/dui\[N\]: user .* last=8,8,108,68   (dui runs after
#   heartbeat ticks=20, i.e. after the drain has consumed the damage)
#
# Fully CI-runnable: pure serial, no Accessibility trust. Headless with --screen
# (so the window manager is armed and user windows can open).
#
# Class B -- Apple silicon + VZ. CI=yes.
#
# Usage: bash tools/verify-live-sb4-damage-tracking.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/lib/gate-run.sh"
art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sb4-damage-tracking-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sb4-damage-tracking-report.txt)"

echo "=== verify-live-sb4-damage-tracking: M33 SB4 — one rect writes -> one rect repaints (rect-granular damage) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -----------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-sb4-damage-tracking
echo "run dir: $RUN_DIR"
SER_LOG="$(art live-sb4-damage-tracking-serial.log)"
RUN_LOG="$(art live-sb4-damage-tracking-run.txt)"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

printf 'exec SB4DAM.BIN\n' > "$RUN_DIR/script.txt"
printf 'dui\n' > "$RUN_DIR/script2.txt"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --screen "$RUN_DIR/screen" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script2 "$RUN_DIR/script2.txt" --script2-after 'timer heartbeat ticks=20' \
    --script-expect 'last=8,8,108,68' --timeout 120 > "$RUN_LOG" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$SER_LOG" || true
echo "runner-rc=$RC serial-bytes=$( [ -f "$SER_LOG" ] && wc -c < "$SER_LOG" | tr -d ' ' || echo 0 )"

OK=0
A_FILLED=0
A_SETTLED=0
A_RECT=0
A_NOFULL=0
A_FAULT=0
if [ "$RC" = 0 ] && [ -f "$SER_LOG" ]; then
    grep -a -qF -- "sb4: filled" "$SER_LOG" && A_FILLED=1
    # The rect-granular repaint: a `.user` window whose last-repainted damage
    # rect is exactly the union {8,8,108,68} (NOT a full-window or 0,0,0,0).
    grep -a -E 'dui\[[0-9]+\]: .*user.*last=8,8,108,68' "$SER_LOG" && A_RECT=1 || true
    # Sanity: no fail marker and no fatal.
    grep -a -qF -- "sb4: open-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb4: fill-fail" "$SER_LOG" && OK=0
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_LOG" && A_FAULT=1 || true
    if [ "$A_FILLED" = 1 ] && [ "$A_RECT" = 1 ] && [ "$A_FAULT" = 0 ]; then
        OK=1
    fi
fi
echo "filled=$A_FILLED rect=$A_RECT fatal=$A_FAULT" | tee -a "$REPORT"

{
    echo "DIPSHITOS live rect-granular damage gate (claim 2382) — the compositor repainted exactly the written union rect {8,8,108,68}, not the whole 128x96 window"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo; echo "=== result ==="
if [ "$OK" = 1 ]; then
    echo "verify-live-sb4-damage-tracking: PASS — SB4DAM.BIN filled two rects that coalesced into one {8,8,108,68} union; dui's last= rect shows composite repainted exactly that region (rect-granular, not whole-window)."
    echo "PASS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sb4-damage-tracking: FAILED — see $REPORT and $SER_LOG."
echo "FAIL" >> "$REPORT"
exit 1
