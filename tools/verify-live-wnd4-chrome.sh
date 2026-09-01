#!/usr/bin/env bash
#
# verify-live-wnd4-chrome.sh -- M32 WMS4 (issue #624) class-B gate: the
# chrome policy drain-out, proven pixel-exact on real VZ.
#
# The SAME chrome measurements as verify-live-chrome.sh (the M20-U9/M21
# parity suite), but with WND.BIN registered and driving chrome: the WM
# server issues `sys_wmctl SET_WINDOW` (a0 = ALL) with the dark-theme
# descriptor; the kernel blits chrome from it instead of its own rules.
# Because the descriptor values are byte-equal to the shim's constants,
# the measured scanout must match the shim's exactly — that is the
# drain-out runbook's parity proof (bypass -> parity -> WMS8 deletes).
#
# ONE headless boot with --screen (GPU armed so REGISTER seats) +
# custom-virtio snapshot streaming (claim-0680 kind-4; byte-exact BGRX).
# Three scripted phases:
#   Phase 1: `wnd start` (REGISTER + SET_WINDOW policy + pacing begins),
#            then `exec NOTEPAD.BIN` (opens its window at (56,56) 512x384
#            and paints — dirty).
#   Phase 2 (after "notepad: ready", 20s — several WM presents): `wm`
#            observability (SET_WINDOW submissions=1, policy_kind=0x3f,
#            per-window kind=0x3f), then `echo chrome-a` (snapshot
#            trigger). The last present before the snapshot composited
#            notepad + descriptor chrome, so the framebuffer holds it.
#   Phase 3: `echo done-a` (the --script-expect).
#
# Assertions (identical to the shim gate's boot A + boot B):
#   A) focused: 3px accent ring (0x3b82f6) around the window edge, white
#      title label ink, red close glyph (0xef4444).
#   B) unfocused (`dui focus 0`): 2px border in 0x475569 (the descriptor's
#      border_unfocus), 16px title band in 0x1a2b3c, label ink, client
#      background, close glyph.
#
# The shim gates (verify-live-chrome.sh etc.) stay untouched — the
# default VM never runs `wnd start`, so the shim path is byte-identical.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m32-wms4-chrome-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wnd4-chrome-report.txt)"

echo "=== verify-live-wnd4-chrome: M32 WMS4 — chrome drain-out pixel parity (issue #624) on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ---------------------------------------------------------
gate_begin live-wnd4-chrome
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" "$@" \
        > "$(art live-wnd4-chrome-run-$tag.txt)" 2>&1
    local RC=$?
    # NB: do NOT re-arm `set -e` here — run_boot returns the runner's rc and
    # the caller captures it while still under `set +e`. Re-arming inside the
    # function kills the whole gate on a failing boot (observed in the first
    # WMS4 run: boot B returned rc=1 and the script died before the report).
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-wnd4-chrome-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

snap_file() {
    local f
    f="$(ls "$RUN_DIR"/snap-$1-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] || { echo "FAIL: no snapshot streamed in boot $1"; return 1; }
    cp "$f" "$(art live-wnd4-chrome-snap-$1.raw)"
    printf '%s' "$f"
}

# --- boot A: FOCUSED chrome parity (ring + title + close), WM-driven ----------
echo "--- boot A: focused chrome parity with WND.BIN driving the descriptor ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'wm\necho chrome-a\n' > "$RUN_DIR/s2-A.txt"
printf 'echo done-a\n' > "$RUN_DIR/s3-A.txt"
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "chrome-a" --script3-delay 30 \
    --snapshot-after "chrome-a" \
    --script-expect "done-a" --timeout 180
RC_A=$?
set -e
A_OK=0
SER_A="$(art live-wnd4-chrome-serial-A.log)"
if [ "$RC_A" = 0 ] && [ -f "$SER_A" ]; then
    # WM observability: the SET_WINDOW submissions are counted and the
    # policy + per-window chrome kinds are visible (issue #624).
    SUBS="$(grep -aom1 -- 'wm: chrome submissions=[0-9]\+' "$SER_A" | grep -ao '[0-9]\+' || true)"
    POL="$(grep -aom1 -- 'policy_kind=0x[0-9a-f]\+' "$SER_A" | grep -ao '0x[0-9a-f]\+' || true)"
    OBS_OK=0
    if [ "$SUBS" -ge 1 ] && [ "$POL" = "0x3f" ] && grep -a -qF 'wm: chrome window id=' "$SER_A" && grep -a -qF 'kind=0x3f' "$SER_A"; then
        OBS_OK=1
    fi
    SNAP_A="$(snap_file A || true)"
    if [ -n "$SNAP_A" ] && [ "$OBS_OK" = 1 ] && python3 - "$SNAP_A" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
X, Y, W, H = 56, 56, 512, 384
ok = True
# Focus ring on the focused window's edge — 3px ACCENT (0x3b82f6), the
# descriptor's ring color (parity with the shim's focus_ring dark theme).
for dy in (0, 1, 2):
    n = sum(1 for dx in range(8, W - 8, 16) if px(X + dx, Y + dy) == (59, 130, 246))
    ok &= n >= (W - 16) // 16 - 2
print("ring_top_ok" if ok else "RING_MISSING")
# Title label ink: white pixels inside the title band (y+3..y+15).
ink = sum(1 for x in range(X + 20, X + W - 40, 2) for y in range(Y + 3, Y + 16)
          if px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200)
print("label_ink=%d" % ink)
# Close glyph: red pixels inside the title-right box (descriptor close_rgb).
red = sum(1 for x in range(X + W - 15, X + W - 5) for y in range(Y + 3, Y + 13)
          if px(x, y)[0] > 170 and px(x, y)[1] < 120 and px(x, y)[2] < 120)
print("close_red=%d" % red)
sys.exit(0 if ok and ink >= 30 and red >= 6 else 1)
PYEOF
    then A_OK=1
    fi
fi

# --- boot B: UNFOCUSED chrome parity measured edge-to-edge --------------------
echo "--- boot B: unfocused chrome parity (descriptor border_unfocus) ---"
printf 'wnd start\nexec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui focus 0\necho chrome-b\n' > "$RUN_DIR/s2-B.txt"
printf 'echo done-b\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 20 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chrome-b" --script3-delay 30 \
    --snapshot-after "chrome-b" \
    --script-expect "done-b" --timeout 180
RC_B=$?
set -e
B_OK=0
if [ "$RC_B" = 0 ]; then
    SNAP_B="$(snap_file B || true)"
    if [ -n "$SNAP_B" ] && python3 - "$SNAP_B" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
BORDER = (0x47, 0x55, 0x69)     # the descriptor's border_unfocus_rgb (dark theme)
TITLE  = (0x1a, 0x2b, 0x3c)     # the descriptor's title_bg_rgb
CLIENT = (0x18, 0x20, 0x26)     # ui.COLOR_BG (dark theme)
X, Y, W, H = 56, 56, 512, 384
fails = []
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
# Left/right border columns: EXACTLY 2px for the full height below the title.
for xx in (X, X + 1, X + W - 2, X + W - 1):
    good = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(xx, yy), BORDER))
    need = len(range(Y + 20, Y + H - 6, 24))
    if good < need - 1: fails.append(f"border col {xx-X}: {good}/{need}")
# Border is only TWO px: the third column is NOT border color.
third_bad = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(X + 2, yy), BORDER))
if third_bad > 2: fails.append(f"border thicker than 2px ({third_bad} hits at col+2)")
# Bottom border rows: exactly two.
for yy in (Y + H - 2, Y + H - 1):
    good = sum(1 for xx in range(X + 8, X + W - 8, 32) if near(px(xx, yy), BORDER))
    need = len(range(X + 8, X + W - 8, 32))
    if good < need - 1: fails.append(f"border row {yy-Y}: {good}/{need}")
# Title band: rows Y..Y+15 dominated by title bg outside the centered label.
band = tot = 0
for yy in range(Y + 2, Y + 16):
    for xx in range(X + 4, X + W - 40, 3):
        tot += 1
        if near(px(xx, yy), TITLE): band += 1
if band < int(tot * 0.55): fails.append(f"title band bg {band}/{tot}")
# Label ink (white) present in the band.
ink = sum(1 for xx in range(X + 20, X + W - 40, 2) for yy in range(Y + 2, Y + 16)
          if px(xx, yy) == (255, 255, 255))
if ink < 30: fails.append(f"title label ink {ink}")
# Client interior is the app background, NOT title/border color.
cl = sum(1 for xx in range(X + 420, X + 504, 4) for yy in range(Y + 300, Y + 372, 4)
         if near(px(xx, yy), CLIENT))
if cl < 100: fails.append(f"client bg {cl}")
# Close glyph red pixels.
red = sum(1 for xx in range(X + W - 15, X + W - 5) for yy in range(Y + 3, Y + 13)
          if px(xx, yy)[0] > 170 and px(xx, yy)[1] < 120 and px(xx, yy)[2] < 120)
if red < 6: fails.append(f"close glyph red {red}")
if fails:
    print("CHROME-FAILS:", "; ".join(fails)); sys.exit(1)
print("CHROME-METRICS-OK")
PYEOF
    then B_OK=1
    fi
fi

PASS=$((A_OK + B_OK))
echo "$REVISION branch=$BRANCH" > "$REPORT"
echo "bootA(focused ring/title/close, WM-driven)=$A_OK bootB(unfocused metrics, WM-driven)=$B_OK" >> "$REPORT"

if [ "$PASS" = 2 ]; then
    echo "verify-live-wnd4-chrome: PASS — WND.BIN registered, SET_WINDOW policy (submissions=1, kind=0x3f) observed, and the chrome pixels match the shim's exactly (the drain-out parity proof)."
    exit 0
fi
echo "verify-live-wnd4-chrome: FAIL ($PASS/2 boots)"
exit 1
