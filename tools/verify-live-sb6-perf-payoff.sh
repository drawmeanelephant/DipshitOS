#!/usr/bin/env bash
#
# verify-live-sb6-perf-payoff.sh -- M33 SB6 (claim 6864) class-B gate:
# measure seam B against the WMS9 baselines, live on real VZ hardware.
#
# ONE headless boot, THREE scripted programs, TWO snapshots:
#   Phase 1 (the "before" control):  SB6OLD.BIN opens a 256x192 user window
#     and renders an 8x8 grid (static + 8 dynamic redraws) through the
#     FROZEN per-rect path — 576 `sys_win_fill` (slot 13) SVCs + 9
#     `sys_win_present` (slot 14) SVCs, each present kernel-blitted.
#   Phase 2 (the seam-B "after"):    SB6WM.BIN registers as the WM server
#     (slot 65), binds the SCANOUT writable (the SB5 grant), and waits
#     (sleep-paced).
#     SB6NEW.BIN opens the SAME window, binds a shared surface, renders the
#     SAME 8x8 grid with PLAIN STORES ONLY (zero fills, sleep-paced), and hands
#     {owner_pid, handle, magic} to the WM, which compose-N's the surface
#     into the scanout at the window rect — COUNTING every byte copied
#     (256*192*4 = 196,608) — reads the byte back, issues the FINAL
#     present, and acks the owner.
#   Snapshot: `syscalls` + `dui` (script2, after heartbeat ticks=30).
#
# The before/after numbers, measured in the SAME boot:
#   - fill SVCs: slot 13 must be exactly 576 (SB6OLD's fills; SB6NEW adds
#     ZERO — plain stores never reach the kernel fill path).
#   - composite cost: dui's `blits=` (kernel user-window blits, the
#     pre-seam-B cost) and `skips=` (surface-backed windows the kernel
#     skipped while the WM owns the user layer) both >= 9 (one per
#     present) — the WM's compose-N replaced the kernel's blits.
#   - copy volume: SB6WM's byte counter = 196,608 bytes per compose,
#     moved with zero kernel fill SVCs.
#
# Serial evidence (gate's grep targets, pinned host-side in sb6_old /
# sb6_new / sb6_wm):
#   sb6: wm registered   sb6: wm scanout=1   sb6: old fills=576
#   sb6: old done        sb6: new ready       sb6: new bound
#   sb6: new fills=0 stores=ok                sb6: wm bytes=196608
#   sb6: wm readback=0x6B                     sb6: wm present
#   sb6: new done        sb6: wm done
#   `13 sys_win_fill calls=576` (syscalls snapshot)
#   dui ... blits=N skips=M (both >= 9)
#
# Fully CI-runnable: pure serial, no Accessibility trust. Headless with
# --screen (so the WM can register and the scanout grant has a framebuffer).
#
# Class B -- Apple silicon + VZ. CI=yes.
#
# Usage: bash tools/verify-live-sb6-perf-payoff.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/tools/lib/gate-run.sh"
art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-sb6-perf-payoff-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-sb6-perf-payoff-report.txt)"

echo "=== verify-live-sb6-perf-payoff: M33 SB6 — measure seam B against the WMS9 baselines (fills / composite cost / copy volume, before vs after in one boot) ==="

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

gate_begin live-sb6-perf-payoff
gate_seed_share
echo "run dir: $RUN_DIR"
SER_LOG="$(art live-sb6-perf-payoff-serial.log)"
RUN_LOG="$(art live-sb6-perf-payoff-run.txt)"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

# WM first (registers + binds the scanout), then the pre-seam-B control,
# then the seam-B owner (which hands the WM its surface for compose-N).
printf 'exec SB6WM.BIN\nexec SB6OLD.BIN\nexec SB6NEW.BIN\n' > "$RUN_DIR/script.txt"
# The before/after observables: the per-slot syscall counters (slot 13 must
# be exactly 576 — only SB6OLD fills) and dui (blits= vs skips=).
# dui FIRST so it lands in the serial before the runner's script-expect
# (the syscalls line) fires and the VM exits; both are evidence.
printf 'dui\nsyscalls\n' > "$RUN_DIR/script2.txt"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --screen "$RUN_DIR/screen" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script2 "$RUN_DIR/script2.txt" --script2-after 'timer heartbeat ticks=45' \
    --script-expect '13 sys_win_fill calls=576' --timeout 180 > "$RUN_LOG" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$SER_LOG" || true
echo "runner-rc=$RC serial-bytes=$( [ -f "$SER_LOG" ] && wc -c < "$SER_LOG" | tr -d ' ' || echo 0 )"

OK=0
A_WM_REG=0
A_SCANOUT=0
A_OLD_FILLS=0
A_OLD_DONE=0
A_NEW_READY=0
A_NEW_BOUND=0
A_NEW_STORED=0
A_NEW_DONE=0
A_BYTES=0
A_READBACK=0
A_PRESENT=0
A_WM_DONE=0
A_FILLS576=0
A_BLITS=0
A_SKIPS=0
A_FAULT=0
if [ "$RC" = 0 ] && [ -f "$SER_LOG" ]; then
    grep -a -qF -- "sb6: wm registered" "$SER_LOG" && A_WM_REG=1
    grep -a -qF -- "sb6: wm scanout=1" "$SER_LOG" && A_SCANOUT=1
    grep -a -qF -- "sb6: old fills=576" "$SER_LOG" && A_OLD_FILLS=1
    grep -a -qF -- "sb6: old done" "$SER_LOG" && A_OLD_DONE=1
    grep -a -qF -- "sb6: new ready" "$SER_LOG" && A_NEW_READY=1
    grep -a -qF -- "sb6: new bound" "$SER_LOG" && A_NEW_BOUND=1
    grep -a -qF -- "sb6: new fills=0 stores=ok" "$SER_LOG" && A_NEW_STORED=1
    grep -a -qF -- "sb6: new done" "$SER_LOG" && A_NEW_DONE=1
    grep -a -qF -- "sb6: wm bytes=196608" "$SER_LOG" && A_BYTES=1
    grep -a -qF -- "sb6: wm readback=0x6B" "$SER_LOG" && A_READBACK=1
    grep -a -qF -- "sb6: wm present" "$SER_LOG" && A_PRESENT=1
    grep -a -qF -- "sb6: wm done" "$SER_LOG" && A_WM_DONE=1
    # The before/after fill count: slot 13 exactly 576 (SB6OLD's control;
    # SB6NEW's plain stores add zero).
    grep -a -E '13 sys_win_fill calls=576' "$SER_LOG" && A_FILLS576=1 || true
    # Composite cost: parse dui's blits= / skips= (>= 9 — one per present).
    DUI_LINE="$(grep -a 'dui: windows=' "$SER_LOG" | head -1 || true)"
    BLITS="$(printf '%s\n' "$DUI_LINE" | sed -n 's/.* blits=\([0-9][0-9]*\).*/\1/p')"
    SKIPS="$(printf '%s\n' "$DUI_LINE" | sed -n 's/.* skips=\([0-9][0-9]*\).*/\1/p')"
    echo "dui-line: $DUI_LINE"
    echo "dui blits=$BLITS skips=$SKIPS"
    if [ -n "$BLITS" ] && [ "$BLITS" -ge 9 ]; then A_BLITS=1; fi
    if [ -n "$SKIPS" ] && [ "$SKIPS" -ge 9 ]; then A_SKIPS=1; fi
    # Sanity: no fail markers and no fatal.
    grep -a -qF -- "sb6: wm register-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: wm scanout-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: wm attach-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: wm compose-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: old open-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: new open-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: new bind-fail" "$SER_LOG" && OK=0
    grep -a -qF -- "sb6: new no-wm" "$SER_LOG" && OK=0
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_LOG" && A_FAULT=1 || true
    if [ "$A_WM_REG" = 1 ] && [ "$A_SCANOUT" = 1 ] && [ "$A_OLD_FILLS" = 1 ] && [ "$A_OLD_DONE" = 1 ] && [ "$A_NEW_READY" = 1 ] && [ "$A_NEW_BOUND" = 1 ] && [ "$A_NEW_STORED" = 1 ] && [ "$A_NEW_DONE" = 1 ] && [ "$A_BYTES" = 1 ] && [ "$A_READBACK" = 1 ] && [ "$A_PRESENT" = 1 ] && [ "$A_WM_DONE" = 1 ] && [ "$A_FILLS576" = 1 ] && [ "$A_BLITS" = 1 ] && [ "$A_SKIPS" = 1 ] && [ "$A_FAULT" = 0 ]; then
        OK=1
    fi
fi
echo "wm_reg=$A_WM_REG scanout=$A_SCANOUT old_fills=$A_OLD_FILLS old_done=$A_OLD_DONE new_ready=$A_NEW_READY new_bound=$A_NEW_BOUND new_stored=$A_NEW_STORED new_done=$A_NEW_DONE bytes=$A_BYTES readback=$A_READBACK present=$A_PRESENT wm_done=$A_WM_DONE fills576=$A_FILLS576 blits=$A_BLITS skips=$A_SKIPS fatal=$A_FAULT" | tee -a "$REPORT"

{
    echo "VIRELAIOS live seam-B perf-payoff gate (claim 6864) — SB6OLD (before): 576 slot-13 fills + kernel blits; SB6NEW (after): 0 fills, plain stores into a shared surface; SB6WM compose-N moved 196,608 bytes into the scanout (readback=0x6B); syscalls snapshot shows '13 sys_win_fill calls=576' and dui blits/skips both >= 9 — the measured before/after in one boot"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

echo; echo "=== result ==="
if [ "$OK" = 1 ]; then
    echo "verify-live-sb6-perf-payoff: PASS — before: SB6OLD issued 576 sys_win_fill SVCs + kernel blits; after: SB6NEW rendered the same frame with plain stores (0 fills, kernel skipped its surface-backed window) and the WM compose-N'd 196,608 bytes into the scanout — the seam-B payoff is measured, not asserted."
    echo "PASS" >> "$REPORT"
    exit 0
fi
echo "verify-live-sb6-perf-payoff: FAILED — see $REPORT and $SER_LOG."
echo "FAIL" >> "$REPORT"
exit 1
