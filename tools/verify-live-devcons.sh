#!/usr/bin/env bash
#
# verify-live-devcons.sh -- M22 D14 (issue #337) class-B gate:
# DEVCONS.BIN — the developer console — on real VZ hardware.
#
# Issue #553 (this gate's D14 asterisk): the original gate only proved the
# window path (app loads, window opens, `devcons: ready`, screenshot). The
# full gate shape — typing a command at the in-window prompt and watching
# the command echo land in the log pane — was blocked upstream by #179
# (synthesized keyboard seam reports events=0). #179 is closed and the
# claim 9588 custom-virtio INPUT channel is productionized (proven
# end-to-end by the #563 typing gate), so this gate now proves the typed
# command path:
#
#   1. boot with the GPU; exec DEVCONS.BIN; wait for `devcons: ready`
#   2. type `dir.bin\n` at the in-window prompt over the custom-virtio
#      INPUT queue (claim 9588) via --input-string/--input-string-after
#   3. DEVCONS buffers the keys and executes the command via sys_exec;
#      DIR.BIN (headless, prints to serial, opens no window) runs as the
#      child — its `dir: listing /host` / `dir: success` serial markers
#      prove the typed command actually executed
#   4. assert the input path decoded every keystroke (input events=8:
#      d i r . b i n Enter), and prove the in-window echo was RENDERED
#      with a screenshot pixel check for white glyphs in the log pane
#      (the `> dir.bin` + `exec: ok (output on serial)` lines drawn by
#      the app itself)
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots a real VM (SPIKE runner,
# --via-virtio).
#
# Usage:
#   bash tools/verify-live-devcons.sh
#
# Evidence saved under artifacts/: live-devcons-gate.txt,
# live-devcons-report.txt, live-devcons-run-*.txt, live-devcons-serial-*.log,
# devcons-screen-5s*, gpu-screen-*.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-devcons-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-devcons-report.txt)"

echo "=== verify-live-devcons: M22 D14 — DEVCONS.BIN developer console on VZ (issue #553 typed-input proof), $BOOTS boot(s) ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-devcons
gate_seed_share
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
exec DEVCONS.BIN
EOF

# Phase 2 sweep (issue #553): after the typed command has executed and the
# log pane re-rendered, dump the input report + process table, then the
# expect marker. The screenshot marker (tick 30) must precede the sweep
# marker (tick 35): the runner's expect-check finishes the VM the poll it
# sees the expect marker, before the capture could fire.
cat > "$RUN_DIR/script2.txt" <<'EOF'
input
procs
echo devcons-typed-sweep-done
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    rm -f "$RUN_DIR"/gpu-screen-*
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$RUN_DIR/gpu-screen" \
        --via-virtio \
        --script "$SCRIPT" \
        --input-string $'dir.bin\n' \
        --input-string-after "devcons: ready" \
        --script2 "$RUN_DIR/script2.txt" \
        --script2-after "timer heartbeat ticks=35" \
        --screenshot-after "timer heartbeat ticks=30" \
        --script-expect "devcons-typed-sweep-done" \
        --timeout 90 \
        > "$(art live-devcons-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-devcons-serial-$tag.log)" || true
    cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
    local SER="$(art live-devcons-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 LOADED=0 OPEN=0 READY=0 TYPED=0 DIRLIST=0 DIRSUC=0 EVENTS=0 ALIVE=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "exec: loaded DEVCONS.BIN size=" "$SER" && LOADED=1
        grep -qF -- "devcons: open" "$SER" && OPEN=1
        grep -qF -- "devcons: ready" "$SER" && READY=1
        # The typed command reached the app: DIR.BIN ran as its child
        # (sys_exec) and printed to serial.
        grep -qF -- "dir: listing /host" "$SER" && DIRLIST=1
        grep -qF -- "dir: success" "$SER" && DIRSUC=1
        # All 8 keystrokes (d i r . b i n Enter) were decoded.
        grep -aq "input: armed=0 fifo=0/64 dropped=0 events=8" "$SER" && EVENTS=1
        grep -qF -- "[EXC] parking" "$SER" || ALIVE=1
    fi

    # Screenshot pixel proof: the log pane re-rendered the command echo.
    local PIXELS=0
    local SHOT="artifacts/gpu-screen-after${SUFFIX}"
    if [ -f "$SHOT" ]; then
        if python3 - "$SHOT" <<'PYEOF'
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
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

# DEVCONS window logical (260,24,400,300) -> retina (520,48,800,600) at the
# 2x ScreenCaptureKit scale. The log pane spans retina y 36..496; its text
# rows start at retina y=44 with 24 px pitch. The `> dir.bin` (row 4) and
# `exec: ok (output on serial)` (row 5) echoes land ~y 116..164. Sample a
# wide band of that pane for near-white glyph pixels (text_primary 0xffffff
# on the 0x1a1a2e pane).
white = 0
for y in range(100, 200, 2):
    for x in range(520, 1300, 3):
        r, g, b = px(x, y)
        if min(r, g, b) > 200:
            white += 1
print("white-glyph samples in DEVCONS log pane: %d" % white)
if white < 60:
    print("ERROR: too few white glyph pixels — the command echo was not rendered")
    sys.exit(1)
PYEOF
        then PIXELS=1
        fi
    fi

    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY typed-dir=$DIRLIST dir-success=$DIRSUC events=$EVENTS pixels=$PIXELS alive=$ALIVE"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER loaded=$LOADED open=$OPEN ready=$READY typed-dir=$DIRLIST dir-success=$DIRSUC events=$EVENTS pixels=$PIXELS alive=$ALIVE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$LOADED" = 1 ] && [ "$OPEN" = 1 ] && [ "$READY" = 1 ] && [ "$DIRLIST" = 1 ] && [ "$DIRSUC" = 1 ] && [ "$EVENTS" = 1 ] && [ "$PIXELS" = 1 ] && [ "$ALIVE" = 1 ]
}

PASS=0
i=1
while [ "$i" -le "$BOOTS" ]; do
    TAG="$(printf '%02d' "$i")"
    if run_one "$TAG"; then
        PASS=$((PASS + 1))
    fi
    i=$((i + 1))
done

gate_end

[ "$PASS" -ge 1 ] || { echo "verify-live-devcons: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-devcons-report.txt)"; exit 1; }
echo "=== verify-live-devcons: PASS — DEVCONS.BIN loaded, opened its split-screen console window, and EXECUTED A TYPED COMMAND live on VZ ($PASS/$BOOTS boot(s)); issue #553 closed. ==="
