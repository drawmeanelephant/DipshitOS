#!/usr/bin/env bash
# tools/verify-live-wallpaper.sh — Class-B live hardware gate for Issue #825:
# Raster Graphics (IMG4): Toolkit draw_image alpha blit & WND.BIN desktop wallpaper.
#
# Proves:
#   1. WND.BIN probes /host/WALLPAPER.QOI on startup via the host file channel.
#   2. WND.BIN decodes the QOI image and scales it to 1280x720 scanout dimensions.
#   3. WND.BIN maps the scanout surface and composites the root wallpaper pixels
#      behind all windows, dock, and taskbar.
#   4. Emits serial synchronization markers:
#      - "wnd: wallpaper loaded"
#      - "wnd: wallpaper present"
#   5. Framebuffer snapshot inspection verifies the distinct wallpaper color
#      is rendered on the desktop at (x=100, y=100).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Modern Homebrew toolchain
source tools/env-check.sh
source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-wallpaper-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-wallpaper-report.txt)"

echo "=== verify-live-wallpaper: M33 IMG4 — WND.BIN desktop wallpaper (issue #825) on VZ ==="

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
gate_begin live-wallpaper
gate_seed_share
echo "run dir: $RUN_DIR"

# Verify /host/WALLPAPER.QOI was seeded by gate_seed_share
[ -f "$RUN_DIR/share/WALLPAPER.QOI" ] || { echo "ERROR: WALLPAPER.QOI missing from share"; exit 1; }
echo "Seeded default mascot wallpaper: $(ls -l "$RUN_DIR/share/WALLPAPER.QOI")"


run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" "$@" \
        > "$(art live-wallpaper-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    cp -f "$RUN_DIR/vm-serial-$tag.log" "$(art live-wallpaper-serial-$tag.log)" 2>/dev/null || true
    return "$RC"
}

snap_file() {
    local f
    f="$(ls "$RUN_DIR"/snap-$1-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] || { echo "FAIL: no snapshot streamed in boot $1"; return 1; }
    cp "$f" "$(art live-wallpaper-snap-$1.raw)"
    printf '%s' "$f"
}

echo "--- boot wallpaper: WND.BIN desktop wallpaper compositing ---"
printf 'wnd start\n' > "$RUN_DIR/script-wp.txt"
printf 'echo done-wp\n' > "$RUN_DIR/s2-wp.txt"

set +e
run_boot wp \
    --script "$RUN_DIR/script-wp.txt" \
    --snapshot-after "wnd: wallpaper present" \
    --script2 "$RUN_DIR/s2-wp.txt" --script2-after "wnd: wallpaper present" --script2-delay 1 \
    --script-expect "done-wp" --timeout 60
RC_WP=$?
set -e

WP_OK=0
SER_WP="$(art live-wallpaper-serial-wp.log)"
if [ "$RC_WP" = 0 ] && [ -f "$SER_WP" ]; then
    echo "WP: runner rc=0"
    if grep -a -qF 'wnd: wallpaper loaded' "$SER_WP" && grep -a -qF 'wnd: wallpaper present' "$SER_WP"; then
        echo "WP: wallpaper loaded and present markers verified"
        SNAP_WP="$(snap_file wp || true)"
        if [ -n "$SNAP_WP" ] && python3 - "$SNAP_WP" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])

# Check wallpaper color at desktop coordinates:
# 1. Dark theme background (#1E1E2E, RGB 30, 30, 46) outside center mascot
WANT_BG = (30, 30, 46)

def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

bg_hits = 0
bg_total = 0
for yy in range(50, 150, 10):
    for xx in range(50, 250, 10):
        bg_total += 1
        c = px(xx, yy)
        if near(c, WANT_BG):
            bg_hits += 1

print(f"wallpaper background pixel hits: {bg_hits}/{bg_total} at corner coordinates")

# 2. Check mascot rendered in the center: blade area at (652, 342) is silver steel
mascot_sample = px(652, 342)
print(f"mascot center sample px(652, 342): {mascot_sample}")
# Steel blade color: high RGB values with metallic sheen (~170, 180, 185)
mascot_ok = near(mascot_sample, (170, 180, 185), tol=12)

if bg_hits >= bg_total - 2 and mascot_ok:
    print("WALLPAPER-PIXELS-OK")
    sys.exit(0)
else:
    print(f"FAIL: bg_hits={bg_hits}/{bg_total}, mascot_ok={mascot_ok}")
    sys.exit(1)
PYEOF
        then
            WP_OK=1
        fi
    fi
else
    echo "WP: runner failed (rc=$RC_WP)"
fi

if [ "$WP_OK" = 1 ]; then
    echo "verify-live-wallpaper: PASS — WND.BIN probed /host/WALLPAPER.QOI, decoded, composited root desktop wallpaper, and pixel verification passed."
    exit 0
else
    echo "verify-live-wallpaper: FAIL"
    exit 1
fi
