#!/usr/bin/env bash
#
# verify-live-image-viewer.sh — M36 IMG5 class-B live gate (issue #826): the
# VIEW.BIN image viewer on real VZ.
#
# Boots the kernel monitor (shell), seeds a QOI into the host share, and
# launches VIEW.BIN with an argument path through the shell
# (`exec VIEW.BIN /host/TEST.QOI` — the claim 4636 argv contract, the same
# direct-exec shape as verify-live-exec / verify-live-sexiburger-actions).
# Asserts the viewer markers, the window-title push, and zoom/pan over the
# headless virtio INPUT channel; the clean-quit contract is the app's own
# `view: quit` marker plus the reaped `user-exec exited status=43` (also the
# --script-expect line, so the VM keeps running until the reap lands).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-image-viewer-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-image-viewer-report.txt)"

echo "=== verify-live-image-viewer: M36 IMG5 VIEW.BIN on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# Build all binaries, the viewer, and the disk image.
zig build
zig build view
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ---
gate_begin live-image-viewer
gate_seed_share
# IMG5: the viewer's test image rides the share (the M34 host file channel).
cp tests/fixtures/qoi/viewer_160x120.qoi "$SHARE/TEST.QOI"
echo "gate-run: seeded $SHARE/TEST.QOI"

echo "run dir: $RUN_DIR"

SCRIPT="$RUN_DIR/script.txt"
cat > "$SCRIPT" <<'EOF'
exec VIEW.BIN /host/TEST.QOI
EOF

# The shell prompt only prints once boot self-tests are done; the default
# --script-after marker ("kernel terminal state") fires even earlier, so pin
# it to the prompt: typing at a not-yet-idle shell drops keystrokes.
SCRIPT_AFTER_LINE="virelai> "

cat > "$RUN_DIR/script2.txt" <<'EOF'
syscalls
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/gpu-screen-*

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$RUN_DIR/gpu-screen-$tag" \
        --via-virtio \
        --script "$SCRIPT" \
        --script-after "$SCRIPT_AFTER_LINE" \
        --input-chords "=,=,=,up,left,right,down,down,down,down,0,-,q" \
        --input-chords-after "view: ready" \
        --screenshot-after "view: ready" \
        --script2 "$RUN_DIR/script2.txt" \
        --script2-after "view: ready" \
        --script-expect "user-exec exited status=43" \
        --timeout 90 \
        > "$(art live-image-viewer-run-$tag.txt)" 2>&1
    local RC=$?
    set -e

    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-image-viewer-serial-$tag.log)" || true
    cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
    local SER="$(art live-image-viewer-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 EXECED=0 OPENED=0 LOADED=0 READY=0
    local TITLE=0 ZIN=0 ZRESET=0 ZOUT=0 PANX=0 PANY=0 QUIT=0 EXIT43=0 SYSCALLS=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "exec: loaded VIEW.BIN" "$SER" && EXECED=1
        grep -qE -- "view: open id=[0-9]+ 328x264" "$SER" && OPENED=1
        grep -qF -- "view: loaded TEST.QOI 160x120 QOI bytes=340" "$SER" && LOADED=1
        grep -qF -- "view: ready" "$SER" && READY=1
        grep -qF -- "view: title set" "$SER" && TITLE=1
        grep -qF -- "view: zoom z=150%" "$SER" && ZIN=1
        grep -qF -- "view: zoom z=100%" "$SER" && ZRESET=1
        grep -qF -- "view: zoom z=66%" "$SER" && ZOUT=1
        # The pan announce is one combined line (`view: pan ox=X oy=Y`);
        # assert each axis actually moved (non-zero).
        grep -qE -- "view: pan ox=[1-9]" "$SER" && PANX=1
        grep -qE -- "view: pan ox=[0-9]+ oy=[1-9]" "$SER" && PANY=1
        grep -qF -- "view: quit" "$SER" && QUIT=1
        grep -qE -- "user-exec exited status=43" "$SER" && EXIT43=1
        grep -qE "sys_win_set_title calls=[0-9]+" "$SER" && SYSCALLS=1
    fi

    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER exec=$EXECED opened=$OPENED loaded=$LOADED ready=$READY title=$TITLE zin=$ZIN zreset=$ZRESET zout=$ZOUT panx=$PANX pany=$PANY quit=$QUIT exit43=$EXIT43 syscalls=$SYSCALLS"
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER exec=$EXECED opened=$OPENED loaded=$LOADED ready=$READY title=$TITLE zin=$ZIN zreset=$ZRESET zout=$ZOUT panx=$PANX pany=$PANY quit=$QUIT exit43=$EXIT43 syscalls=$SYSCALLS" >> "$REPORT"

    if [ $RC -ne 0 ] || [ $BANNER -ne 1 ] || [ $EXECED -ne 1 ] \
        || [ $OPENED -ne 1 ] || [ $LOADED -ne 1 ] || [ $READY -ne 1 ] || [ $TITLE -ne 1 ] \
        || [ $ZIN -ne 1 ] || [ $ZRESET -ne 1 ] || [ $ZOUT -ne 1 ] || [ $PANX -ne 1 ] \
        || [ $PANY -ne 1 ] || [ $QUIT -ne 1 ] || [ $EXIT43 -ne 1 ]; then
        echo "FAIL: $tag failed live assertions" >&2
        return 1
    fi
}

rm -f "$REPORT"
touch "$REPORT"

for b in $(seq 1 "$BOOTS"); do
    tag="boot-$b"
    echo "--- boot $b/$BOOTS ---"
    run_one "$tag"
done

echo "verify-live-image-viewer: PASS ($BOOTS/$BOOTS boots ok) — VIEW.BIN argument exec, decode, title, zoom (+/-/0), pan, and clean quit (status 43) live on VZ."
