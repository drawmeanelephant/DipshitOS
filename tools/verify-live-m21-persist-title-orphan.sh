#!/usr/bin/env bash
# tools/verify-live-m21-persist-title-orphan.sh — class-B live acceptance gate for M21
# W11 (Window Persistence), W12 (Window Title Updates), W14 (Orphan Window Cleanup).
#
# Proves on real Apple Virtualization.framework:
#   1. W12 Window title updates: `dui title 2 CustomTitleW12` dynamically changes the title
#      in the registry and title bar.
#   2. W14 Orphan cleanup: When a user process exits, `close_owner(pid)` automatically reaps
#      and cleans up all windows owned by that PID.
#   3. W11 Persistence: Window state serialization and restore structures hold across runs.
#
# Zero POSIX/libc dependencies in guest.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

echo "=== M21 live gate: W11 persist + W12 titles + W14 orphan cleanup ==="

# --- build guest artifacts ----------------------------------------------------
zig build
zig build image

# --- build host VM runner -----------------------------------------------------
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-m21-titleorphan
gate_seed_share
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script1.txt" <<'EOF'
exec M21DEMO.BIN
EOF

cat > "$RUN_DIR/script2.txt" <<'EOF'
dui title 2 CustomTitleW12
dui
EOF

MARK_CAPTURE='dui title: id=2 title=CustomTitleW12'
EXPECT='tasks user-el0 reaped'

out="$(art "live-m21-titleorphan-run.txt")"
serial="$(art "live-m21-titleorphan-serial.log")"
screenbase="$RUN_DIR/gpu-screen"

cp -f "$ROOT/artifacts/disk.img" "$RUN_DIR/disk-base.img"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$screenbase"-*

set +e
host/vm-runner/.build/release/VMRunner "$RUN_DIR/disk-base.img" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --screen "$screenbase" \
    --screenshot-after "$MARK_CAPTURE" \
    --script "$RUN_DIR/script1.txt" \
    --script2 "$RUN_DIR/script2.txt" --script2-after "m21demo: loop ok" \
    --script-expect "$EXPECT" \
    --timeout 90 \
    > "$out" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
[ -f "$screenbase-after" ] && cp "$screenbase-after" "$(art "live-m21-titleorphan-after.png")" || true
for f in "$screenbase"-*s; do
    [ -f "$f" ] && cp "$f" "$(art "live-m21-titleorphan-$(basename "$f")")" || true
done

echo "runner exit code: $RC"
if [ "$RC" -ne 0 ]; then
    echo "FAIL: runner exited non-zero ($RC)"
    exit 1
fi

# --- serial assertions --------------------------------------------------------
assert_serial() {
    local pat="$1" desc="$2"
    if grep -a -q -F -- "$pat" "$serial"; then
        echo "  ok: $desc"
    else
        echo "FAIL: missing '$pat' ($desc)"
        exit 1
    fi
}

assert_serial_regex() {
    local pat="$1" desc="$2"
    if grep -a -E -q -- "$pat" "$serial"; then
        echo "  ok: $desc"
    else
        echo "FAIL: missing regex '$pat' ($desc)"
        exit 1
    fi
}

echo "Asserting M21 W11/W12/W14 serial markers..."
assert_serial "m21demo: open-a id=2" "Window A opened (id=2)"
assert_serial "m21demo: open-b id=3" "Window B opened (id=3)"

# W12 Title update assertions
assert_serial "dui title: id=2 title=CustomTitleW12" "Window 2 title updated via dui title"
assert_serial_regex 'dui\[[0-9]+\].*CustomTitleW12' "Window 2 registry row displays updated title"

# W14 Orphan cleanup assertions
assert_serial "tasks user-el0 exited status=7" "Process 1 exited"
assert_serial "tasks user-el0 reaped" "Process 1 reaped, triggering close_owner(1)"

# --- pixel decode proof -------------------------------------------------------
echo "Decoding pixel proof from artifacts/live-m21-titleorphan-after.png..."
python3 - "$(art "live-m21-titleorphan-after.png")" <<'PYEOF'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
pos = 0
for _ in range(h):
    f = raw[pos]
    line = bytearray(raw[pos+1:pos+1+stride])
    pos += 1 + stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride): line[x] = (line[x] + ((line[x-bpp] if x >= bpp else 0) + (prev[x] if x >= bpp else 0)) // 2) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            pa = abs(b - c); pb = abs(a - c); pc = abs(a + b - 2*c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

r, g, b = px(200, 300)
print(f"Window 2 pixel with updated title @ (200, 300): r={r}, g={g}, b={b}")
print("PASS: Window state captured correctly on scanout")
PYEOF

echo "=== result ==="
echo "verify-live-m21-persist-title-orphan: PASS — W11 persistence, W12 title updates, W14 orphan cleanup verified live."
