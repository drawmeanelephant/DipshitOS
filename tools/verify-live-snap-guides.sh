#!/usr/bin/env bash
#
# verify-live-snap-guides.sh — M37 DQ5 window snap guides live proof (issue #837)
#
# Proves, in THREE headless VZ boots (one app + one snapshot each, the DQ4
# lesson list: compositor caps user windows at 4, snapshots coalesce, share
# state reset per boot, interior probes only):
#   A. near-edge drag previews: grab NOTEPAD's title at (60,64), drag to the
#      left edge and HOLD (10,300) — `wnd: snap-preview zone=left
#      x=0 y=0 w=640 h=700` prints, and the kind-4 snapshot shows the 2px
#      DQ4-accent outline on the zone bounds with a clean interior. The
#      snapshot fires after `wnd: snap-settled` (eight continuous
#      tick-restores, ~8 s into the hold): the move's own SET_WINDOW damage
#      repaints the desktop over the move-time outline within milliseconds
#      (and any later shell output re-dirties it again), so snapshotting
#      after the drag marker races the wipe — the settled marker is the
#      clean window: restored and stable. Script phases stay after the
#      stream (script2 runs `dui` 30 s after settled, past the ~16 s
#      stream) so their output can't wipe mid-stream.
#   B. release commits: the same drag + release (`,u`) — `wnd: snap` prints
#      and the dui row lands on the previewed left half (rect=64,138,512,).
#   C. center drag is clean: grab + hold at (500,300) — no snap-preview
#      marker, and the snapshot holds no accent pixels on the zone border.
#
# The preview is render-only (never SET_WINDOW); the commit rides the
# unchanged WMS5 snap_window_to path. Existing verify-live-wnd5-geometry.sh
# re-runs green alongside (center-drag geometry untouched).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-snap-guides.sh
# Evidence: artifacts/live-snap-guides-{run.txt,serial.log,snap}-?,
#           artifacts/live-snap-guides-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-snap-guides-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-snap-guides-report.txt)"

echo "=== verify-live-snap-guides: M37 DQ5 window snap guides (issue #837) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/wnd.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-snap-guides
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    # Per-boot share reset (M21 W11 WINDOWS.SAV restore drifts ids across
    # shared-share boots — the DQ3 root cause).
    gate_reset_share_state
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" \
        "$@" \
        > "$(art live-snap-guides-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-snap-guides-serial-$tag.log)" || true
    local f
    f="$(ls "$RUN_DIR"/snap-$tag-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] && cp "$f" "$(art live-snap-guides-snap-$tag.raw)" || true
    echo "$tag: runner rc=$RC snap=${f:-none}"
    return "$RC"
}

printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-base.txt"
# NOTEPAD opens at (56,56) 512x384; its title band is y in [56,72), so
# (60,64) grabs with offset (4,8). Held at (10,300) the window sits at
# (6,292) — clear of every outline probe below.

A_PREV=0; A_NOSNAP=0; A_DONE=0
B_SNAP=0; B_RECT=0; B_DONE=0
C_NOPREV=0; C_DONE=0

# --- boot A: hold at the left edge -> outline --------------------------------
echo "--- boot A: near-edge hold -> snap preview outline ---"
printf 'dui\necho done-a\n' > "$RUN_DIR/s2-A.txt"
set +e
run_boot A \
    --script "$RUN_DIR/script-base.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "wnd: snap-settled" --script2-delay 30 \
    --pointer-virtio "60,64,d;10,300" --pointer-virtio-after "notepad: ready" \
    --snapshot-after "wnd: snap-settled" \
    --script-expect "done-a" --timeout 240
RC_A=$?
set -e
SER_A="$(art live-snap-guides-serial-A.log)"
# NOTE (issue #843): markers print AFTER their syscalls return, so a marker
# PROVES the dispatch applied — rc is reported, not required.
if [ -f "$SER_A" ]; then
    grep -a -qF -- "wnd: snap-preview zone=left x=0 y=0 w=640 h=700" "$SER_A" && A_PREV=1
    grep -a -q "wnd: snap$" "$SER_A" || A_NOSNAP=1
    grep -a -qF -- "done-a" "$SER_A" && A_DONE=1
fi

# --- boot B: release at the edge -> commits to the previewed rect ------------
echo "--- boot B: release at edge -> snap commits ---"
printf 'dui\necho done-b\n' > "$RUN_DIR/s2-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-base.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "wnd: drop" --script2-delay 8 \
    --pointer-virtio "60,64,d;10,300,u" --pointer-virtio-after "notepad: ready" \
    --script-expect "done-b" --timeout 240
RC_B=$?
set -e
SER_B="$(art live-snap-guides-serial-B.log)"
if [ -f "$SER_B" ]; then
    grep -a -q "wnd: snap$" "$SER_B" && B_SNAP=1
    # Left-half centered 512-wide window: x=(640-512)/2=64, y=(700-424)/2=138.
    grep -a -qF -- "rect=64,138,512," <(grep -a 'user user rect=' "$SER_B" | tail -1) && B_RECT=1
    grep -a -qF -- "done-b" "$SER_B" && B_DONE=1
fi

# --- boot C: hold at center -> no outline ------------------------------------
echo "--- boot C: center hold -> no preview ---"
printf 'echo done-c\n' > "$RUN_DIR/s2-C.txt"
set +e
run_boot C \
    --script "$RUN_DIR/script-base.txt" \
    --script2 "$RUN_DIR/s2-C.txt" --script2-after "wnd: drag" --script2-delay 20 \
    --pointer-virtio "60,64,d;500,300" --pointer-virtio-after "notepad: ready" \
    --snapshot-after "wnd: drag" \
    --script-expect "done-c" --timeout 240
RC_C=$?
set -e
SER_C="$(art live-snap-guides-serial-C.log)"
if [ -f "$SER_C" ]; then
    grep -a -qF -- "wnd: snap-preview" "$SER_C" || C_NOPREV=1
    grep -a -qF -- "done-c" "$SER_C" && C_DONE=1
fi

# --- pixel assertions: outline accent on A, absent on C ----------------------
# Dark accent 0x3b82f6 (DQ4 token; WND owns the desktop theme, default dark).
pix_probe() {
    local tag="$1" mode="$2"
    python3 - "$tag" "$mode" <<'PYEOF'
import sys
tag, mode = sys.argv[1], sys.argv[2]
ACC = (0x3b, 0x82, 0xf6)
path = f"artifacts/live-snap-guides-snap-{tag}.raw"
W, H = 1280, 720
try:
    data = open(path, "rb").read()
except FileNotFoundError:
    print(f"{tag}: NO SNAPSHOT"); sys.exit(1)
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    print(f"  {label}: {'ok' if good else f'GOT {got} WANT {want}'}")
def check_not(x, y, ban, label):
    global ok
    got = px(x, y)
    good = got != ban
    ok &= good
    print(f"  {label}: {'ok' if good else f'GOT banned {got}'}")
# Left-half zone (0,0,640x700), 2px band; window held at (6,292) 512x384.
if mode == "outline":
    check(638, 100, ACC, "right edge upper")
    check(639, 600, ACC, "right edge lower")
    check(320, 0, ACC, "top edge")
    check(100, 1, ACC, "top edge left")
    check(320, 699, ACC, "bottom edge")
    check(100, 698, ACC, "bottom edge left")
    check(1, 400, ACC, "left edge")
    check_not(320, 350, ACC, "interior clean (window content)")
    check_not(700, 350, ACC, "outside zone clean (desktop)")
else:
    check_not(638, 100, ACC, "right edge clean")
    check_not(320, 0, ACC, "top edge clean")
    check_not(320, 699, ACC, "bottom edge clean")
print("PIX_OK" if ok else "PIX_MISSING")
sys.exit(0 if ok else 1)
PYEOF
}

P_A=0; P_C=0
if pix_probe A outline; then P_A=1; fi
if pix_probe C clean; then P_C=1; fi

# --- report ------------------------------------------------------------------
{
    echo "--- M37 DQ5 snap guides report ---"
    echo "  boot A (edge hold): rc=$RC_A preview=$A_PREV nosnap=$A_NOSNAP done=$A_DONE pix=$P_A"
    echo "  boot B (release): rc=$RC_B snap=$B_SNAP rect=$B_RECT done=$B_DONE"
    echo "  boot C (center hold): rc=$RC_C nopreview=$C_NOPREV done=$C_DONE pix=$P_C"
    if [ "$A_PREV" = 1 ] && [ "$A_NOSNAP" = 1 ] && [ "$A_DONE" = 1 ] && [ "$P_A" = 1 ] && \
       [ "$B_SNAP" = 1 ] && [ "$B_RECT" = 1 ] && [ "$B_DONE" = 1 ] && \
       [ "$C_NOPREV" = 1 ] && [ "$C_DONE" = 1 ] && [ "$P_C" = 1 ]; then
        echo "  RESULT: PASS"
    else
        echo "  RESULT: FAIL"
    fi
    echo "---"
} | tee "$REPORT"

if [ "$A_PREV" = 1 ] && [ "$A_NOSNAP" = 1 ] && [ "$A_DONE" = 1 ] && [ "$P_A" = 1 ] && \
   [ "$B_SNAP" = 1 ] && [ "$B_RECT" = 1 ] && [ "$B_DONE" = 1 ] && \
   [ "$C_NOPREV" = 1 ] && [ "$C_DONE" = 1 ] && [ "$P_C" = 1 ]; then
    echo "verify-live-snap-guides: PASS — edge hold previews, release commits to the previewed rect, center hold is clean, live on VZ"
    exit 0
else
    echo "verify-live-snap-guides: FAIL"
    exit 1
fi
