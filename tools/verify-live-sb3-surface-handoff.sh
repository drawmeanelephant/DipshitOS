#!/usr/bin/env bash
#
# verify-live-sb3-surface-handoff.sh -- M33 SB3 (claim 3633) class-B gate:
# the window surface handoff, end to end on real VZ hardware (ADR 0016,
# seam B, issue #630). THIS is the milestone's parity gate: a migrated app
# renders into its shared surface with PLAIN STORES and the registered WM
# sees exactly those bytes — what the old kernel sys_win_fill path produced
# by construction (same B8G8R8X8 encoding, different destination memory).
#
# Two EL0 processes:
#   * SB3OWN.BIN — the migrated app half: opens a user window (frozen slot
#     12), BINDS a shared-anonymous surface as its back-buffer via
#     sys_mmap(addr = M33_SURF_WIN_TAG | window_id, MAP_ANON|M33_MAP_SHARED)
#     (slot 63), then renders with plain STORES through its own writable
#     leaf — a magic byte + a colored row — and hands {pid, handle=1, magic}
#     to the WM over the mailbox.
#   * SB3WM.BIN — the WM half: registers as the WM server (slot 65 REGISTER,
#     the D2 trust boundary), PEERS the surface by handle using the SB2 peer
#     attach (EL0-RO sw_cow in ITS OWN root), reads the byte the owner
#     stored, and prints `sb3: wm-read=0xAB` — the WM sees the app's
#     plain-store bytes, proving the handoff (no kernel fill).
#
# Serial evidence (the gate's grep targets, pinned host-side in the apps):
#   sb3: wm registered    sb3: own opened    sb3: own bound
#   sb3: own stored       sb3: wm-read=0xAB  sb3: owner done
#   sb3: wm done
#
# Fully CI-runnable with NO Accessibility trust — pure serial + mailbox, no
# pointer/keyboard injection. Headless with --screen (the WM REGISTER needs
# the GPU armed so gpu_setup sets gpu_setup_ok).
#
# Class B -- Apple silicon + VZ. CI=yes.
#
# Usage:  bash tools/verify-live-sb3-surface-handoff.sh
# Evidence: artifacts/live-sb3-surface-handoff-{run.txt,serial.log},
#           artifacts/live-sb3-surface-handoff-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sb3-surface-handoff-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sb3-surface-handoff-report.txt)"

echo "=== verify-live-sb3-surface-handoff: M33 SB3 — migrated app renders into its shared surface with plain stores; the registered WM reads the bytes (ADR 0016, seam B) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-sb3-surface-handoff
echo "run dir: $RUN_DIR"

SER_LOG="$(art live-sb3-surface-handoff-serial.log)"
RUN_LOG="$(art live-sb3-surface-handoff-run.txt)"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

printf 'exec SB3WM.BIN\nexec SB3OWN.BIN\n' > "$RUN_DIR/script.txt"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --screen "$RUN_DIR/screen" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-expect $'sb3: wm done\n' --timeout 180 > "$RUN_LOG" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$SER_LOG" || true

echo "runner-rc=$RC serial-bytes=$( [ -f "$SER_LOG" ] && wc -c < "$SER_LOG" | tr -d ' ' || echo 0 )"

OK=0
A_WM_REG=0
A_OWN_OPEN=0
A_OWN_BOUND=0
A_OWN_STORED=0
A_WM_READ=0
A_OWN_DONE=0
A_WM_DONE=0
A_FAULT=0
if [ "$RC" = 0 ] && [ -f "$SER_LOG" ]; then
    grep -a -qF -- "sb3: wm registered" "$SER_LOG" && A_WM_REG=1
    grep -a -qF -- "sb3: own opened" "$SER_LOG" && A_OWN_OPEN=1
    grep -a -qF -- "sb3: own bound" "$SER_LOG" && A_OWN_BOUND=1
    grep -a -qF -- "sb3: own stored" "$SER_LOG" && A_OWN_STORED=1
    grep -a -qF -- "sb3: wm-read=0xAB" "$SER_LOG" && A_WM_READ=1
    grep -a -qF -- "sb3: owner done" "$SER_LOG" && A_OWN_DONE=1
    grep -a -qF -- "sb3: wm done" "$SER_LOG" && A_WM_DONE=1
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_LOG" && A_FAULT=1 || true
    if [ "$A_WM_REG" = 1 ] && [ "$A_OWN_OPEN" = 1 ] && [ "$A_OWN_BOUND" = 1 ] && [ "$A_OWN_STORED" = 1 ] && \
        [ "$A_WM_READ" = 1 ] && [ "$A_OWN_DONE" = 1 ] && [ "$A_WM_DONE" = 1 ] && [ "$A_FAULT" = 0 ]; then
        OK=1
    fi
fi
echo "wm-reg=$A_WM_REG own-open=$A_OWN_OPEN own-bound=$A_OWN_BOUND own-stored=$A_OWN_STORED wm-read=$A_WM_READ own-done=$A_OWN_DONE wm-done=$A_WM_DONE fatal=$A_FAULT" | tee -a "$REPORT"

{
    echo "VIRELAIOS live surface-handoff gate (claim 3633) — migrated app renders with plain stores into its shared surface; the registered WM reads the bytes RO (ADR 0016)"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo
echo "=== result ==="
if [ "$OK" = 1 ]; then
    echo "verify-live-sb3-surface-handoff: PASS — the migrated app bound its window to a shared surface, stored magic 0xAB with a plain write; the registered WM peered the surface RO and read 0xAB exactly (surface-handoff parity vs the old fill path)."
    echo "PASS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sb3-surface-handoff: FAILED — see $REPORT and $SER_LOG."
echo "FAIL" >> "$REPORT"
exit 1
