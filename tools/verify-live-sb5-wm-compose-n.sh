#!/usr/bin/env bash
#
# verify-live-sb5-wm-compose-n.sh -- M33 SB5 (claim 7397) class-B gate:
# WM compose-N + one final present, live on real VZ hardware.
#
# SB5WM.BIN registers as the WM server (slot 65), binds the SCANOUT writable
# (the SB5 grant — M33_SURF_SCAN_TAG via sys_mmap), and waits for the owner.
# SB5OWN.BIN opens a 256x192 user window at (320,64), binds a shared surface
# as its back-buffer (SB3 handoff), renders with PLAIN STORES ONLY (it NEVER
# calls sys_win_fill), and hands {pid, handle, magic} to the WM. The WM peers
# the surface RO, COMPOSES it into its scanout view (compose-N: plain byte
# copies at the window rect), reads the byte BACK FROM THE SCANOUT (the
# composited pixel IS the app's store), issues the FINAL present
# (REQUEST_PRESENT cmd 3 — flush only; the kernel never re-paints over the
# WM's stores), and acks the owner.
#
# Serial evidence (gate's grep targets, pinned host-side in sb5_own/sb5_wm):
#   sb5: wm registered   sb5: wm scanout=1   sb5: own opened
#   sb5: own bound       sb5: own stored     sb5: wm readback=0x5B
#   sb5: wm present      sb5: owner done     sb5: wm done
# The zero-fill proof: a script2 `syscalls` run (after heartbeat ticks=20)
# must show `13 sys_win_fill calls=0` — the migrated app never issued a fill
# SVC, and the WM's compose-N produced the scanout pixels instead.
#
# Fully CI-runnable: pure serial, no Accessibility trust. Headless with
# --screen (so the WM can register and the scanout grant has a framebuffer).
#
# Class B -- Apple silicon + VZ. CI=yes.
#
# Usage: bash tools/verify-live-sb5-wm-compose-n.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/lib/gate-run.sh"
art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sb5-wm-compose-n-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sb5-wm-compose-n-report.txt)"

echo "=== verify-live-sb5-wm-compose-n: M33 SB5 — the registered WM composites the migrated surface into the scanout and issues the FINAL present (zero fill SVCs) ==="

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

gate_begin live-sb5-wm-compose-n
echo "run dir: $RUN_DIR"
SER_LOG="$(art live-sb5-wm-compose-n-serial.log)"
RUN_LOG="$(art live-sb5-wm-compose-n-run.txt)"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

# WM first (it registers + binds the scanout), then the migrated owner.
printf 'exec SB5WM.BIN\nexec SB5OWN.BIN\n' > "$RUN_DIR/script.txt"
# The zero-fill observability: the syscalls report after the apps ran.
printf 'syscalls\n' > "$RUN_DIR/script2.txt"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --screen "$RUN_DIR/screen" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script2 "$RUN_DIR/script2.txt" --script2-after 'timer heartbeat ticks=20' \
    --script-expect '13 sys_win_fill calls=0' --timeout 180 > "$RUN_LOG" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$SER_LOG" || true
echo "runner-rc=$RC serial-bytes=$( [ -f "$SER_LOG" ] && wc -c < "$SER_LOG" | tr -d ' ' || echo 0 )"

OK=0
A_WM_REG=0
A_SCANOUT=0
A_OWN_OPEN=0
A_OWN_BOUND=0
A_OWN_STORED=0
A_READBACK=0
A_PRESENT=0
A_OWNER_DONE=0
A_WM_DONE=0
A_ZEROFILL=0
A_FAULT=0
if [ "$RC" = 0 ] && [ -f "$SER_LOG" ]; then
    grep -a -qF -- "sb5: wm registered" "$SER_LOG" && A_WM_REG=1
    grep -a -qF -- "sb5: wm scanout=1" "$SER_LOG" && A_SCANOUT=1
    grep -a -qF -- "sb5: own opened" "$SER_LOG" && A_OWN_OPEN=1
    grep -a -qF -- "sb5: own bound" "$SER_LOG" && A_OWN_BOUND=1
    grep -a -qF -- "sb5: own stored" "$SER_LOG" && A_OWN_STORED=1
    grep -a -qF -- "sb5: wm readback=0x5B" "$SER_LOG" && A_READBACK=1
    grep -a -qF -- "sb5: wm present" "$SER_LOG" && A_PRESENT=1
    grep -a -qF -- "sb5: owner done" "$SER_LOG" && A_OWNER_DONE=1
    grep -a -qF -- "sb5: wm done" "$SER_LOG" && A_WM_DONE=1
    # Zero fill SVCs: the syscalls report must show slot 13 at calls=0.
    grep -a -E '13 sys_win_fill calls=0' "$SER_LOG" && A_ZEROFILL=1 || true
    # Sanity: no fail markers and no fatal.
    grep -a -qF -- "sb5: wm register-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: wm scanout-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: wm attach-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: wm compose-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: own open-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: own bind-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb5: own no-wm" "$SER_LOG" && OK=0
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_LOG" && A_FAULT=1 || true
    if [ "$A_WM_REG" = 1 ] && [ "$A_SCANOUT" = 1 ] && [ "$A_OWN_OPEN" = 1 ] && [ "$A_OWN_BOUND" = 1 ] && [ "$A_OWN_STORED" = 1 ] && [ "$A_READBACK" = 1 ] && [ "$A_PRESENT" = 1 ] && [ "$A_OWNER_DONE" = 1 ] && [ "$A_WM_DONE" = 1 ] && [ "$A_ZEROFILL" = 1 ] && [ "$A_FAULT" = 0 ]; then
        OK=1
    fi
fi
echo "wm_reg=$A_WM_REG scanout=$A_SCANOUT own_open=$A_OWN_OPEN own_bound=$A_OWN_BOUND own_stored=$A_OWN_STORED readback=$A_READBACK present=$A_PRESENT owner_done=$A_OWNER_DONE wm_done=$A_WM_DONE zerofill=$A_ZEROFILL fatal=$A_FAULT" | tee -a "$REPORT"

{
    echo "VIRELAIOS live WM compose-N + one final present gate (claim 7397) — the registered WM composited the migrated surface into the scanout (readback=0x5B) and issued the final present; zero sys_win_fill SVCs (slot 13 calls=0)"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo; echo "=== result ==="
if [ "$OK" = 1 ]; then
    echo "verify-live-sb5-wm-compose-n: PASS — SB5WM.BIN registered, bound the scanout, composited SB5OWN's plain-store surface into it (readback=0x5B), issued the final present, and the kernel reported sys_win_fill calls=0: a registered-WM desktop composited entirely from shared surfaces with ZERO fill SVCs."
    echo "PASS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sb5-wm-compose-n: FAILED — see $REPORT and $SER_LOG."
echo "FAIL" >> "$REPORT"
exit 1
