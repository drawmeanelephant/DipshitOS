#!/usr/bin/env bash
# verify-live-wm7-gateb.sh — M32 WMS7 Gate B live gate (issue #627).
#
# THE TOOLKIT RE-POINT: the toolkit (`user/src/lib/ui.zig`) now carries a
# WM_RPC client ("ask the WM"), and WMRPC.BIN — the acceptance app — rides
# it. Two proofs:
#
#   * WM round-trip THROUGH THE TOOLKIT (boot A): `wnd start` + NOTEPAD
#     (window 2) + `exec WMRPC.BIN`. WMRPC discovers the WM + its own pid
#     via `ui.wm_peers`, opens its own window, then issues WIN_RAISE and
#     WIN_CONFIG via `ui.wm_mail_request` (the toolkit client) instead of
#     hand-rolled mail. The WM still serves (`wnd: mail kind=1/2
#     applied=yes`), the acks return (`wmrpc: raise-ack/config-ack`), the
#     raise moves focus back to NOTEPAD, and the config rect applies.
#
#   * no-WM syscall fallback (boot B): with the shim compositing (no WM),
#     the toolkit's `ui.wm_raise_front` / `ui.wm_config` must fall back to
#     the FROZEN syscalls (`sys_win_raise_front` slot 49, `sys_win_move`
#     slot 16) so a toolkit app behaves identically with or without a WM.
#     WMRPC detects no WM (`wmrpc: no-wm`), then exercises the fallback on
#     NOTEPAD's window and prints `wmrpc: fallback raise/ok` — proving the
#     syscall path is intact and the re-point is additive.
#
# Fully CI-runnable with NO Accessibility trust — pure serial + mailbox, no
# pointer/keyboard injection (exactly like verify-live-wm-ipc.sh).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wm7-gateb.sh
# Evidence: artifacts/live-wm7-gateb-{A,B}-{run.txt,serial.log},
#           artifacts/live-wm7-gateb-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/627

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wm7-gateb-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wm7-gateb-report.txt)"

echo "=== verify-live-wm7-gateb: M32 WMS7 Gate B — the toolkit learns WM_RPC (issue #627) ==="

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
gate_begin live-wm7-gateb
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        "$@" \
        > "$(art live-wm7-gateb-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wm7-gateb-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: the toolkit round-trip -----------------------------------------
echo "--- boot A: WMRPC asks the WM THROUGH THE TOOLKIT (ui.wm_mail_request) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'exec WMRPC.BIN\necho wmipc-a2-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\nwm\necho wmipc-a2-done\n' > "$RUN_DIR/s3-A.txt"
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 6 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "wmrpc: done" --script3-delay 8 \
    --script-expect "wmipc-a2-done" --timeout 240
RC_A=$?
set -e
A_OK=0; A_MAIL_RAISE=0; A_MAIL_CONFIG=0; A_ACK_RAISE=0; A_ACK_CONFIG=0
A_FOCUS=0; A_RECT=0; A_PRESENT=0
SER_A="$(art live-wm7-gateb-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    grep -a -qF -- "wnd: mail kind=1 id=2 seq=1 applied=yes" "$SER_A" && A_MAIL_RAISE=1
    grep -a -qF -- "wnd: mail kind=2 id=2 seq=2 applied=yes title=wm-rpc" "$SER_A" && A_MAIL_CONFIG=1
    grep -a -qF -- "wmrpc: raise-ack applied=yes" "$SER_A" && A_ACK_RAISE=1
    grep -a -qF -- "wmrpc: config-ack applied=yes" "$SER_A" && A_ACK_CONFIG=1
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_A" && A_FOCUS=1
    grep -a -qE -- "dui\\[[0-9]+\\]: user user rect=40,40,360,260" "$SER_A" && A_RECT=1
    grep -a -qF -- "wnd: present" "$SER_A" && A_PRESENT=1
    if [ "$A_MAIL_RAISE" = 1 ] && [ "$A_MAIL_CONFIG" = 1 ] && [ "$A_ACK_RAISE" = 1 ] && [ "$A_ACK_CONFIG" = 1 ] && [ "$A_FOCUS" = 1 ] && [ "$A_RECT" = 1 ] && [ "$A_PRESENT" = 1 ]; then
        A_OK=1
    fi
fi
echo "  runner rc=$RC_A  mail_raise=$A_MAIL_RAISE  mail_config=$A_MAIL_CONFIG  ack_raise=$A_ACK_RAISE  ack_config=$A_ACK_CONFIG  focused=$A_FOCUS  rect=$A_RECT  wm_present=$A_PRESENT"
echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"

# --- boot B: the no-WM syscall fallback through the toolkit ------------------
echo "--- boot B: no WM — ui.wm_raise_front/ui.wm_config fall back to the frozen syscalls ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/sB.txt"
printf 'exec WMRPC.BIN\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\necho wmfail-b-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/sB.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: open" --script2-delay 5 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "wmrpc: no-wm" --script3-delay 6 \
    --script-expect "wmfail-b-done" --timeout 240
RC_B=$?
set -e
B_OK=0; B_NOWM=0; B_FALLBACK=0; B_MOVED=0; B_FAULT=0
SER_B="$(art live-wm7-gateb-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    grep -a -qF -- "wmrpc: no-wm" "$SER_B" && B_NOWM=1
    # The toolkit's fallback markers (ui.wm_raise_front fell back to
    # sys_win_raise_front slot 49, ui.wm_config to sys_win_move slot 16 —
    # the additive path). Both must succeed on WMRPC's own window.
    grep -a -qF -- "wmrpc: fallback raise=ok move=ok" "$SER_B" && B_FALLBACK=1
    # The fallback move actually landed: WMRPC's own window now sits at the
    # config rect (40,40) — the dui row proves the byte-identical syscall path.
    grep -a -qE -- "dui\\[[0-9]+\\]: user user rect=40,40," "$SER_B" && B_MOVED=1
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_B" && B_FAULT=1
    if [ "$B_NOWM" = 1 ] && [ "$B_FALLBACK" = 1 ] && [ "$B_MOVED" = 1 ] && [ "$B_FAULT" = 0 ]; then
        B_OK=1
    fi
fi
echo "  runner rc=$RC_B  no_wm=$B_NOWM  fallback=$B_FALLBACK  moved=$B_MOVED  fault=$B_FAULT"
echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"

# --- report ------------------------------------------------------------------
{
    echo "--- WMS7 Gate B live report (issue #627) ---"
    echo "boot A (WM registered, toolkit mail round-trip):"
    echo "  rc=$RC_A  mail_raise=$A_MAIL_RAISE  mail_config=$A_MAIL_CONFIG  ack_raise=$A_ACK_RAISE  ack_config=$A_ACK_CONFIG"
    echo "  focused=$A_FOCUS  rect=$A_RECT  wm_present=$A_PRESENT  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (no WM, toolkit syscall fallback):"
    echo "  rc=$RC_B  no_wm=$B_NOWM  fallback=$B_FALLBACK  moved=$B_MOVED  fault=$B_FAULT  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "GATE PASS"
    else
        echo "GATE FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps ----------------------------------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: WMRPC asking the WM through the toolkit]" >> "$REPORT"
    grep -a -E "wnd: mail|wmrpc:|dui: windows=|dui\\[[0-9]+\\]: user user rect=" "$SER_A" | head -10 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the no-WM syscall fallback through the toolkit]" >> "$REPORT"
    grep -a -E "wmrpc: no-wm|wmrpc: fallback|dui: windows=" "$SER_B" | head -6 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi