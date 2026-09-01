#!/usr/bin/env bash
#
# verify-live-wnd8-unsaved-drain.sh — M32 WMS8 Gate 4 (issue #628) class-B
# gate: the unsaved-changes dialog (Arc4 #242) drains into WND.BIN policy.
#
# WMS6 left the modal/transient dialogs on the WMS8 backlog ("modal dialogs
# remain on the WMS8 delete-runbook backlog"). Gates 2+3 drained + deleted
# the about dialog; Gate 4 (claim 6155) does the same for the unsaved-changes
# confirmation:
#
#   * The kind-20 WM_WINDOW mirror gains an UNSAVED bit (flags bit 12): the
#     kernel's `user_set_unsaved` fans it so the registered WM learns each
#     window's dirty state as it changes (the WM's decision input).
#   * The slot-65 DIALOG subcommand (cmd 11) gains actions 3 (show),
#     4 (save), 5 (don't save), 6 (cancel), applied through the kernel's OWN
#     `unsaved_dialog_*` primitives (parity by construction).
#   * WND.BIN owns the decision: a close-button DOWN EDGE on a DIRTY mirror
#     shows the dialog (DIALOG 3); a click on a dialog button applies the
#     choice (DIALOG 4/5/6) via the SHARED `wnd_core.unsaved_dialog_choice_at`
#     rule — the same rects the kernel's `unsaved_dialog_click` applies.
#   * The kernel's own decision is DELETED: the pointer_tick dialog intercept,
#     the close-button dirty-check, and the 5-tick auto-close timeout.
#
# Two boots prove both halves:
#   * Boot A (shim, no WM): NOTEPAD.BIN opens, `dui unsaved 2 1` marks it
#     dirty, and a REAL custom-virtio pointer click lands on the close glyph
#     (558,64). The kernel's dirty-check is DELETED, so shim mode closes the
#     dirty window IMMEDIATELY (`notepad: win_close`, no dialog, no
#     `win_unsaved`, no fault) — the issue's "no compositing policy"
#     end-state for the no-WM boot.
#   * Boot B (WM-driven): `wnd start`, NOTEPAD.BIN opens, `dui unsaved 2 1`
#     sets the dirty flag AND fans the kind-20 mirror (bit 12). A REAL click
#     on the close glyph hits the WM's mirror: the WM sees unsaved=true,
#     decides, and issues DIALOG 3 (`wnd: unsaved-dialog`). A second REAL
#     click on the Don't Save button (660,390) — the WM decides discard
#     (DIALOG 5, `wnd: unsaved-discard`), the kernel applies
#     `unsaved_dialog_dont_save`, and NOTEPAD closes (`notepad: win_close`).
#     Serial proof: `wnd: unsaved-dialog` + `wnd: unsaved-discard` markers
#     AND a nonzero `dialog=` count in the `wm` observability row AND the
#     applied close (the kernel did not self-decide — it no longer can).
#     Review fix (claim 7639): boot B ALSO asserts NO `wnd: grab`/`wnd: drag`/
#     `wnd: drop` markers — the close click must not start a title-bar drag
#     (the DOWN EDGE is consumed by the dialog).
#
# The pointer steps pace at 2.5 s each on the headless custom-virtio channel
# (claim 9367), so two clicks in one sequence land as distinct DOWN EDGEs.
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-wnd8-unsaved-drain.sh
# Evidence: artifacts/live-wnd8-unsaved-{A,B}-{run.txt,serial.log},
#           artifacts/live-wnd8-unsaved-report.txt
#
# Issue: https://github.com/drawmeanelephant/DipshitOS/issues/628

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-wnd8-unsaved-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-wnd8-unsaved-report.txt)"

echo "=== verify-live-wnd8-unsaved-drain: M32 WMS8 Gate 4 — the unsaved-changes dialog drains into WND.BIN and the kernel decision is deleted (issue #628) ==="

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
gate_begin live-wnd8-unsaved
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
        > "$(art live-wnd8-unsaved-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e` (the WMS4 lesson).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd8-unsaved-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

# --- boot A: shim (no WM) — dirty close is immediate, no dialog ----------------
# No WM seated -> the kernel's dirty-check is DELETED (Gate 4): a REAL close
# click on a DIRTY NOTEPAD closes it immediately — no dialog, no WIN_UNSAVED,
# no fault. This is the issue's "no compositing policy" shim end-state.
echo "--- boot A: no WM — closing a dirty window closes it immediately (the kernel no longer self-decides) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui unsaved 2 1\nwm\necho dirty-a\n' > "$RUN_DIR/s2-A.txt"
printf 'echo shim-done\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo shim-done'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "558,64,c" --pointer-virtio-after "dirty-a" \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "dirty-a" --script3-delay 20 \
    --script-expect "$EXPECT_A" --timeout 260
RC_A=$?
set -e
A_OK=0
A_CLOSED=0; A_DIALOG=0; A_FAULT=0
SER_A="$(art live-wnd8-unsaved-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The dirty flag was set, then the close click closed the window.
    grep -a -qF -- "dui unsaved: id=2 flag=1" "$SER_A" && A_DIRTY=1
    grep -a -qF -- "notepad: win_close" "$SER_A" && A_CLOSED=1
    # 2) NO dialog: no WM decision marker and no WIN_UNSAVED to the app
    #    (the kernel applied close, not a self-decided dialog).
    grep -a -qF -- "wnd: unsaved-dialog" "$SER_A" && A_DIALOG=1
    grep -a -qF -- "notepad: win_unsaved" "$SER_A" && A_DIALOG=1
    # 3) No real fault/panic.
    grep -a -qE -- "(panic|abort|kernel fault|data abort)" "$SER_A" && A_FAULT=1
    if [ "${A_DIRTY:-0}" = 1 ] && [ "$A_CLOSED" = 1 ] && [ "$A_DIALOG" = 0 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: the WM-driven unsaved-changes dialog ------------------------------
# WND.BIN registered. The dirty flag is set (which fans the kind-20 mirror
# with bit 12 — the WM's decision input). A REAL close click hits the WM's
# mirror: the WM sees unsaved=true and shows the dialog (DIALOG 3). A second
# REAL click on Don't Save: the WM decides discard (DIALOG 5), the kernel
# applies `unsaved_dialog_dont_save`, and NOTEPAD closes. The kernel must NOT
# self-decide — its dirty-check is deleted.
echo "--- boot B: a WM-driven unsaved-changes dialog (the kernel does not decide) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui unsaved 2 1\nwm\necho dirty-go\n' > "$RUN_DIR/s2-B.txt"
printf 'wm\necho unsaved-done\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "558,64,c;660,390,c" --pointer-virtio-after "dirty-go" \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "dirty-go" --script3-delay 20 \
    --script-expect "unsaved-done" --timeout 260
RC_B=$?
set -e
B_OK=0
WM_SHOW=0; WM_DISCARD=0; APPLY=0; CLOSED=0; PRESENT=0
SER_B="$(art live-wnd8-unsaved-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM decided to show the dialog: its `wnd: unsaved-dialog` marker.
    grep -a -qF -- "wnd: unsaved-dialog" "$SER_B" && WM_SHOW=1
    # 2) The WM decided the choice: `wnd: unsaved-discard` (Don't Save).
    grep -a -qF -- "wnd: unsaved-discard" "$SER_B" && WM_DISCARD=1
    # 3) The kernel applied the WM's DIALOG (the cmd-11 counter is nonzero in
    #    the `wm` observability row — an applied decision, not a dropped one).
    grep -a -qE -- "dialog=[1-9][0-9]*" "$SER_B" && APPLY=1
    # 4) The discard actually closed NOTEPAD.
    grep -a -qF -- "notepad: win_close" "$SER_B" && CLOSED=1
    # 5) The WM stayed seated + pacing.
    grep -a -qF -- "wnd: present" "$SER_B" && PRESENT=1
    # 6) Review fix (claim 7639): the close click did NOT also start a
    #    title-bar drag — the close rect is inside the title band, and the
    #    DOWN EDGE must be consumed by the dialog (the kernel shim set
    #    handled_btn and broke; the WM must match). No grab/drag/drop markers.
    NODRAG=0
    grep -a -qE -- "wnd: (grab|drag|drop)" "$SER_B" && NODRAG=1
    if [ "$WM_SHOW" = 1 ] && [ "$WM_DISCARD" = 1 ] && [ "$APPLY" = 1 ] && [ "$CLOSED" = 1 ] && [ "$PRESENT" = 1 ] && [ "$NODRAG" = 0 ]; then
        B_OK=1
    fi
fi

# --- report ------------------------------------------------------------------
{
    echo "$REVISION branch=$BRANCH"
    echo "bootA(shim dirty-close immediate, no dialog)=$A_OK bootB(WM unsaved dialog + discard)=$B_OK"
} > "$REPORT"

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    echo "verify-live-wnd8-unsaved-drain: PASS (shim closes dirty immediately; WM shows + decides the unsaved dialog; kernel applied, did not decide)"
    exit 0
else
    echo "verify-live-wnd8-unsaved-drain: FAIL (A=$A_OK B=$B_OK)"
    echo "--- boot A evidence ---"; [ -f "$SER_A" ] && grep -a -E "dui unsaved|win_close|win_unsaved|unsaved-dialog|panic|abort" "$SER_A" | tail -20 || true
    echo "--- boot B evidence ---"; [ -f "$SER_B" ] && grep -a -E "wnd: unsaved|win_close|dialog=[0-9]|wnd: present|panic|abort" "$SER_B" | tail -30 || true
    exit 1
fi
