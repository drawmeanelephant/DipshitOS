#!/usr/bin/env bash
#
# verify-live-wm-ipc.sh — M32 WMS7 Gate A (issue #627) class-B gate: the
# app↔WM mailbox protocol (WM_RPC) end-to-end.
#
# Apps ask the WM through the per-process mailbox (sys_ipc_send slot 5 /
# sys_ipc_recv slot 6) instead of syscalling the desktop. WMRPC.BIN discovers
# the registered WM (WND.BIN) + its own pid via sys_procs (slot 7), opens its
# own user window, then sends TWO bounded WM_RPC requests to the WM:
#   WIN_RAISE  (kind 1) -> the WM focuses+raises the target via ALT_TAB-commit
#   WIN_CONFIG (kind 2) -> the WM clamps+applies a new rect (+bounded title)
# WND.BIN's tick loop drains its own inbox (<= 1 s latency), applies through
# its OWN clamped primitives, replies with the ack, and prints `wnd: mail`.
# The app polls for the ack and prints `wmrpc: raise-ack / config-ack`.
#
# Fully CI-runnable with NO Accessibility trust — pure serial + mailbox, no
# pointer/keyboard injection.
#
# Two boots prove both halves:
#   * Boot A (WM registered): `wnd start` + NOTEPAD (window 2) +
#     `exec WMRPC.BIN` (no args — the gate topology is hardcoded: target 2 = NOTEPAD's
#     window, wm = WND.BIN; WMRPC ignores argv so it never needs argv room). Serial proof: `wnd: mail kind=1 id=2
#     seq=1 applied=yes` + `kind=2 ... title=wm-rpc` (the WM SERVED the
#     requests), `wmrpc: raise-ack applied=yes` + `config-ack applied=yes`
#     (the replies RETURNED to the app), the raise moved focus
#     (`dui: windows=.. focused=2` — WMRPC's own window had focused 3 first),
#     and the config applied (`dui[2]: user user rect=40,40,360,260`).
#   * Boot B (shim, no WM): `exec WMRPC.BIN` finds no WM server,
#     prints `wmrpc: no-wm` and parks — the protocol is additive (apps that
#     can't reach a WM keep working through the frozen syscalls).
#
# The mailbox-bound honesty contract (full ring -> ENOSPC, no loss) is the
# existing `verify-live-ipc.sh` gate — re-run separately in the sweep; this
# gate rides the same bounded rings without perturbing them.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wm-ipc.sh
# Evidence: artifacts/live-wm-ipc-{A,B}-{run.txt,serial.log},
#           artifacts/live-wm-ipc-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/627

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wm-ipc-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wm-ipc-report.txt)"

echo "=== verify-live-wm-ipc: M32 WMS7 Gate A — the app↔WM mailbox protocol (WM_RPC) end-to-end (issue #627) ==="

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
gate_begin live-wm-ipc
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
        > "$(art live-wm-ipc-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wm-ipc-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot B first (the no-WM back-compat proof) --------------------------------
# No WM registered -> WMRPC finds no WND.BIN in the process table, prints
# `wmrpc: no-wm` and parks. The shim desktop is untouched — additive.
echo "--- boot B: no WM — WMRPC degrades gracefully (additive back-compat) ---"
printf 'exec WMRPC.BIN\n' > "$RUN_DIR/sB.txt"
# Expect the app's OWN marker: the runner exits 0 the moment `wmrpc: no-wm`
# lands in the serial log — proving the app actually ran, found no WM server,
# and degraded gracefully (an instant `echo` would tear the VM down before
# the app's first quantum, which is exactly what made the first gate run fail
# with an empty app transcript).
EXPECT_B='wmrpc: no-wm'
set +e
run_boot B \
    --script "$RUN_DIR/sB.txt" \
    --script-expect "$EXPECT_B" --timeout 180
RC_B=$?
set -e
B_OK=0
B_NOWM=0
B_FAULT=0
SER_B="$(art live-wm-ipc-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The app detected no WM server and degraded gracefully.
    grep -a -qF -- "wmrpc: no-wm" "$SER_B" && B_NOWM=1
    # 2) No real fault/panic (exclude the benign `efault` uaccess boot tests).
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_B" && B_FAULT=1
    if [ "$B_NOWM" = 1 ] && [ "$B_FAULT" = 0 ]; then
        B_OK=1
    fi
fi

# --- boot A: the WM round-trip --------------------------------------------------
# WM registered + NOTEPAD (window 2). WMRPC opens its own window (focus moves
# to 3), then WIN_RAISE 2 (focus back to 2) and WIN_CONFIG 2 (rect -> 40,40,
# 360,260 + title "wm-rpc"), each acked back to the app over the mailbox.
echo "--- boot A: WMRPC raises + configures a window THROUGH the WM (mail, not syscalls) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'exec WMRPC.BIN\necho wmipc-a-go\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\nwm\necho wmipc-a-done\n' > "$RUN_DIR/s3-A.txt"
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 6 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "wmrpc: done" --script3-delay 8 \
    --script-expect "wmipc-a-done" --timeout 240
RC_A=$?
set -e
A_OK=0
A_MAIL_RAISE=0
A_MAIL_CONFIG=0
A_ACK_RAISE=0
A_ACK_CONFIG=0
A_FOCUS=0
A_RECT=0
A_PRESENT=0
SER_A="$(art live-wm-ipc-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The WM SERVED the raise request (its `wnd: mail` marker, kind 1).
    grep -a -qF -- "wnd: mail kind=1 id=2 seq=1 applied=yes" "$SER_A" && A_MAIL_RAISE=1
    # 2) The WM SERVED the config request (kind 2) with the title round-trip.
    grep -a -qF -- "wnd: mail kind=2 id=2 seq=2 applied=yes title=wm-rpc" "$SER_A" && A_MAIL_CONFIG=1
    # 3) The replies RETURNED to the app (its ack markers, applied).
    grep -a -qF -- "wmrpc: raise-ack applied=yes" "$SER_A" && A_ACK_RAISE=1
    grep -a -qF -- "wmrpc: config-ack applied=yes" "$SER_A" && A_ACK_CONFIG=1
    # 4) The raise moved focus to NOTEPAD (the post-run dui header; WMRPC's
    #    own window opening had focused 3 first).
    grep -a -qE -- "dui: windows=[0-9]+ focused=2" "$SER_A" && A_FOCUS=1
    # 5) The config applied the WM's rect (the post-run dui row).
    grep -a -qE -- "dui\\[[0-9]+\\]: user user rect=40,40,360,260" "$SER_A" && A_RECT=1
    # 6) The WM stayed seated + pacing through the run.
    grep -a -qF -- "wnd: present" "$SER_A" && A_PRESENT=1
    if [ "$A_MAIL_RAISE" = 1 ] && [ "$A_MAIL_CONFIG" = 1 ] && [ "$A_ACK_RAISE" = 1 ] && [ "$A_ACK_CONFIG" = 1 ] && [ "$A_FOCUS" = 1 ] && [ "$A_RECT" = 1 ] && [ "$A_PRESENT" = 1 ]; then
        A_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "--- WMS7 Gate A live report ---"
    echo "boot A (WM registered, WMRPC round-trip):"
    echo "  runner rc=$RC_A  mail_raise=$A_MAIL_RAISE  mail_config=$A_MAIL_CONFIG  ack_raise=$A_ACK_RAISE  ack_config=$A_ACK_CONFIG  focused=$A_FOCUS  rect=$A_RECT  wm_present=$A_PRESENT"
    echo "  RESULT: $([ "$A_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "boot B (no WM, back-compat):"
    echo "  runner rc=$RC_B  no_wm=$B_NOWM  fault=$B_FAULT"
    echo "  RESULT: $([ "$B_OK" = 1 ] && echo PASS || echo FAIL)"
    echo "---"
    if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
        echo "verify-live-wm-ipc: PASS — WMRPC raised + configured a window THROUGH the WM over the mailbox (WM served + acked both), the raise moved focus, the config rect applied, and with no WM the app degrades gracefully (additive back-compat)"
    else
        echo "verify-live-wm-ipc: FAIL"
    fi
} | tee "$REPORT"

# --- evidence greps (the report's serial proof) ------------------------------
if [ -f "$SER_A" ]; then
    echo "[serial A: the WM serving + the app's acks + the applied effects]" >> "$REPORT"
    grep -a -E "wnd: mail|wmrpc:|dui: windows=|dui\\[[0-9]+\\]: user user rect=" "$SER_A" | head -10 >> "$REPORT" || true
fi
if [ -f "$SER_B" ]; then
    echo "[serial B: the graceful no-WM degradation]" >> "$REPORT"
    grep -a -E "wmrpc: no-wm" "$SER_B" | head -3 >> "$REPORT" || true
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "GATE PASS"
else
    echo "GATE FAIL"
    exit 1
fi
