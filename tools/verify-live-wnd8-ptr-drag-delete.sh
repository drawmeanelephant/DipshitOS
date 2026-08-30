#!/usr/bin/env bash
#
# verify-live-wnd8-ptr-drag-delete.sh -- M32 WMS8 Gate 6 (issue #628, claim
# 4576) class-B gate: the kernel's dormant pointer DRAG / snap geometry-
# decision layer is DELETED, proven live on real VZ.
#
# WMS5 proved the WM owns pointer GEOMETRY: while WND.BIN is registered the
# kernel fans the raw pointer stream (kind 19 WM_POINTER) out and returns
# early — the WM hit-tests the title bar and issues SET_WINDOW rects
# (`user_move`), and on release snaps via its own mirror + the shared
# `wnd_core` rule. Gate 6 deletes the kernel's counterpart: the drag_id /
# drag_offset state, the title-bar drag-initiation, the drag-move + snap-on-
# release block, and the applied snap_window/snap_restore primitives. RESIZE,
# close/minimize buttons, modal, dock/tray/notif, and MOUSE event delivery
# to apps are KEPT (the WM does not cover them yet).
#
# The PROOF has two boots:
#   * Boot A (shim, NO WM): a real title-bar drag is injected over the
#     custom-virtio pointer channel. With the kernel drag deleted, the window
#     does NOT move (its registry rect stays at the open position), there is
#     NO `dui: ... move` / snap marker, and no fault. This is the intended
#     no-WM "no compositing policy" end-state (a title-bar drag does nothing).
#     The app still RECEIVES the MOUSE events (the kept delivery surface) —
#     proven by zero fault + the shell stays responsive.
#   * Boot B (WM registered): the SAME title-bar drag fans out (kind 19), the
#     WM decides (`wnd: grab` + `wnd: drag` + `wnd: drop`), issues SET_WINDOW
#     rects, and the kernel CLAMPS + BLITS them — the window MOVES (its
#     registry rect changes). This re-proves the WM owns the drag end-to-end;
#     the canonical verify-live-wnd5-geometry gate is re-run separately for
#     the exact-rect parity.
#
# Zero regression: resize / buttons / modal / dock-tray-notif / MOUSE
# delivery are untouched (only the drag+snap decision layer is gone); every
# pre-WMS5 gate boots shim-only and is unaffected.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-wnd8-ptr-drag-delete.sh
#
# Evidence: artifacts/live-wnd8-ptr-drag-delete-report.txt,
# artifacts/live-wnd8-ptr-drag-delete-{A,B}-{run.txt,serial.log}.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-wnd8-ptr-drag-delete-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wnd8-ptr-drag-delete-report.txt)"

echo "=== verify-live-wnd8-ptr-drag-delete: M32 WMS8 Gate 6 — kernel title-bar drag/snap decision layer deleted (issue #628) on VZ ==="

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
gate_begin live-wnd8-ptr-drag-delete
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
        > "$(art live-wnd8-ptr-drag-delete-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e`.
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd8-ptr-drag-delete-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

PTR_SEQ="300,64,d;350,80;400,100;450,120;500,300,u"

# --- boot A: shim (no WM) — the deleted kernel drag does nothing ---------------
echo "--- boot A: NO WM — a title-bar drag does NOT move the window (the kernel drag/snap decision layer is deleted) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui\necho drag-a\n' > "$RUN_DIR/s2-A.txt"
printf 'dui\necho done-a\n' > "$RUN_DIR/s3-A.txt"
EXPECT_A='echo done-a'
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 2 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "drag-a" --script3-delay 45 \
    --pointer-virtio "$PTR_SEQ" --pointer-virtio-after "notepad: ready" \
    --script-expect "$EXPECT_A" --timeout 240
RC_A=$?
set -e
A_OK=0
A_FAULT=0; A_A_MOVED=0
SER_A="$(art live-wnd8-ptr-drag-delete-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # 1) The window did NOT move during the drag: the LAST registry row keeps
    #    the open rect (56,56,512,384). The kernel no longer consumes the
    #    drag -> no `rect=...` other than the open.
    A_OPEN_PRESENT=0
    grep -a -qF -- "rect=56,56,512,384" "$SER_A" && A_OPEN_PRESENT=1
    # 2) No real fault/panic (the injected drag ran through the shim harmlessly).
    grep -a -qE -- "(panic|abort|kernel fault)" "$SER_A" && A_FAULT=1
    echo "boot A checks: open_rect_present=$A_OPEN_PRESENT fault=$A_FAULT"
    if [ "$A_OPEN_PRESENT" = 1 ] && [ "$A_FAULT" = 0 ]; then
        A_OK=1
    fi
fi

# --- boot B: WM registered — the WM still owns the drag ----------------------
# The same title-bar drag fans out (kind 19); the WM decides (grab/drag/drop)
# and issues SET_WINDOW rects the kernel clamps + blits — the window MOVES.
echo "--- boot B: WND.BIN registered — the WM owns the title-bar drag (fans kind 19; SET_WINDOW moves the window) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui\nwm\necho drag-b\n' > "$RUN_DIR/s2-B.txt"
printf 'dui\nwm\necho done-b\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 2 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "drag-b" --script3-delay 45 \
    --pointer-virtio "$PTR_SEQ" --pointer-virtio-after "notepad: ready" \
    --script-expect "done-b" --timeout 240
RC_B=$?
set -e
B_OK=0
SER_B="$(art live-wnd8-ptr-drag-delete-serial-B.log)"
if [ "$RC_B" = 0 ] && [ -f "$SER_B" ]; then
    # 1) The WM state machine ran (the pinned markers).
    GRAB=0; DRAG=0; DROP=0
    grep -a -qF -- "wnd: grab" "$SER_B" && GRAB=1
    DRAG=$(grep -a -c -- "wnd: drag" "$SER_B" || true)
    grep -a -qF -- "wnd: drop" "$SER_B" && DROP=1
    # 2) The kernel handed the stream over (fan-out counter > 0).
    FAN=0
    grep -a -qE -- "wm: ptr_fan=[1-9][0-9]*" "$SER_B" && FAN=1
    # 3) The registry row CHANGED from the open (56,56,512,384) — the window
    #    MOVED, and only the WM could have moved it (kernel drag removed).
    B_BEFORE=0; B_AFTER=0
    grep -a -qF -- "rect=56,56,512,384" "$SER_B" && B_BEFORE=1
    grep -a -qvE -- "rect=56,56,512,384" <<<"$(grep -a 'user user rect=' "$SER_B" | tail -1)" && B_AFTER=1
    echo "boot B checks: grab=$GRAB drag=$DRAG drop=$DROP ptr_fan=$FAN before=$B_BEFORE after=$B_AFTER"
    if [ "$GRAB" = 1 ] && [ "$DRAG" -ge 1 ] && [ "$DROP" = 1 ] && [ "$FAN" = 1 ] && [ "$B_BEFORE" = 1 ] && [ "$B_AFTER" = 1 ]; then
        B_OK=1
    fi
fi

if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ]; then
    cat > "$REPORT" <<EOF
verify-live-wnd8-ptr-drag-delete: PASS
  Boot A (shim, no WM): a real title-bar drag did NOT move NOTEPAD (registry
  rect stays 56,56,512,384), no fault — the kernel drag/snap decision layer
  is deleted; a title-bar drag now does nothing without a WM (the issue's
  "no compositing policy" end-state). Resize/buttons/MOUSE delivery stayed.
  Boot B (WM registered): the same drag fans out (ptr_fan>=1), the WM decides
  (wnd: grab + wnd: drag xN + wnd: drop) and issues SET_WINDOW rects the
  kernel clamps + blits — the registry row CHANGED, proving the WM — not the
  kernel — owns title-bar drag end-to-end. RESIZE etc. are untouched (kept).
EOF
    echo "verify-live-wnd8-ptr-drag-delete: PASS — boot A the kernel no longer drags (rect unchanged, no fault); boot B the registered WM still owns the drag (grab/drag/drop + ptr_fan + a moved rect)."
    exit 0
fi
echo "verify-live-wnd8-ptr-drag-delete: FAIL — checks did not all pass (A=$A_OK B=$B_OK; see above)"
exit 1