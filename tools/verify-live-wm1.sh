#!/usr/bin/env bash
#
# verify-live-wm1.sh -- Lane 1 WM1 (#707, claim 919) class-B gate: eight
# concurrent pool-backed user windows on real Apple silicon
# Virtualization.framework hardware.
#
# The gate execs eight GUI programs from the monitor (WINLOOP first — it
# hard-requires id 2 — then CALC, NOTEPAD, TOP, DESKTOP, FILE, SYSMON,
# PS), each of which opens exactly one user window through slot 12
# sys_win_open and keeps it alive. It asserts all eight ready markers,
# the `dui` registry dump (4 fixed + 8 user rows), and the syscalls
# report `12 sys_win_open calls=8` — the on-hardware proof of the WM1 ceiling
# (4 → 8) with page-pool back-buffers. Pixel content of pool buffers is
# proven by the host unit tests (driving_award round-trip + realloc);
# multi-app compositing by verify-live-desktop.sh.
#
# EDIT.BIN is deliberately NOT among the eight: at 245,928 bytes file /
# 361,768 bytes resident (text+data+bss tail) it exceeds the monitor-exec
# 256 KiB staging bound (`too_large`, pre-existing — not WM1).
# DESKTOP.BIN (20 KiB) execs fine; one host-channel stat flake under
# rapid execs was observed once, so the eight execs are split 5+3 across
# the two script phases with ready-marker gating between them.
#
# Task budget: shell + worker + idle + 8 EL0t = 11/11 (scheduler
# max_tasks) — exactly full, which is itself the ceiling proof. The
# static boot payload must have exited first (STATIC_EXIT_LINE, the same
# sequencing verify-live-exec.sh uses).
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk, EFI var store, serial log, and screen captures under $RUN_DIR.
# Set VIRELAI_GATE_SUFFIX=_alt for distinct evidence names.
#
# Usage:
#   bash tools/verify-live-wm1.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-wm1-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wm1-report.txt)"

echo "=== verify-live-wm1: Lane 1 WM1 (#707) — eight pool-backed windows on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-wm1
gate_seed_share
echo "run dir: $RUN_DIR"

# WINLOOP.BIN first: it hard-requires id 2 (parks otherwise). The rest
# take ids 3..9 in exec order. All eight persist (yield/event loops).
# Split 5+3 across the two script phases so the second batch only
# starts once the first five are demonstrably up (host-channel pacing).
cat > "$RUN_DIR/script.txt" <<'EOF'
exec WINLOOP.BIN
exec CALC.BIN
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

cat > "$RUN_DIR/script2.txt" <<'EOF'
exec FILE.BIN
exec SYSMON.BIN
exec PS.BIN
EOF

cat > "$RUN_DIR/script3.txt" <<'EOF'
dui
syscalls
echo done-wm1-sweep
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Opening eight windows on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
rm -f "$RUN_DIR"/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --input --screen "$RUN_DIR/gpu-screen" \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "desktop: ready" \
    --script3 "$RUN_DIR/script3.txt" \
    --script3-after "ps: ready" \
    --script-expect "done-wm1-sweep" \
    --timeout 150 > "$(art live-wm1-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-wm1-serial.log)" || true
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
SER="$(art live-wm1-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-wm1-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying eight windows ---"

for marker in "winloop: open id=2" "calc: ready" "notepad: ready" "top: ready" "desktop: ready" "file: ready" "sysmon: ready" "ps: ready"; do
    grep -q "$marker" "$SER" || {
        echo "ERROR: marker missing from serial log: $marker"
        exit 1
    }
    echo "$marker: OK"
done

# The ceiling proof: eight slot-12 opens in the syscall accounting, and
# the `dui` registry dump shows 4 fixed + 8 user windows (ids 2..9 via
# eight `user rect=` rows).
grep -q "12 sys_win_open calls=8" "$SER" || {
    echo "ERROR: sys_win_open call count != 8 in syscalls report"
    grep -E "12 sys_win_open" "$SER" || true
    exit 1
}
echo "CEILING (8 opens): OK"
grep -q "dui: windows=12 " "$SER" || {
    echo "ERROR: registry count != 12 (4 fixed + 8 user) in dui dump"
    grep -E "dui: windows=" "$SER" || true
    exit 1
}
USER_ROWS="$(grep -c " user rect=" "$SER" || true)"
[ "$USER_ROWS" = "8" ] || {
    echo "ERROR: registry shows $USER_ROWS user windows, want 8"
    exit 1
}
echo "REGISTRY (4 fixed + 8 user): OK"

grep -q "done-wm1-sweep" "$SER" || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Lane 1 WM1 Live Gate Report (#707, claim 919) ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Eight concurrent pool-backed user windows (ids 2..9), one per program:
WINLOOP (id 2) + CALC + NOTEPAD + TOP + DESKTOP + FILE + SYSMON + PS.
sys_win_open (slot 12): calls=8 in the syscalls report.

Serial Output Highlights:
$(grep -E '(winloop|calc|notepad|top|desktop|file|sysmon|ps):' "$SER" || true)
EOF

echo "verify-live-wm1: PASS — eight pool-backed windows live on VZ."
