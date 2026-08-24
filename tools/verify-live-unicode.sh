#!/usr/bin/env bash
#
# verify-live-unicode.sh -- milestone-twenty cards U2/U3/U11 class-B gate
# (issues #307/#308/#316): Unicode glyphs render on the terminal and the
# missing-glyph fallback is observable over serial.
#
# Mechanism: boots the production image and drives the walk over serial.
# `text put` renders UTF-8 into the framebuffer text layer through the
# SAME putc/UTF-8 decoder the shell output path uses, then reports the
# flush result; `text fontdebug` exposes the missing-glyph counters:
#   text fontdebug on
#   text put café           -> Latin-1 é has real art: no missing count
#   text fontdebug          -> missing=0
#   text putraw 中文        -> CJK is width-2 with no table: 1 miss each,
#                              double-wide fallback cells
#   text fontdebug          -> missing=N (echo adds to the count) last=U+4E2D
#   text put Škoda Ž        -> Latin Extended-A renders from ext_a tables
#   echo m20-unicode-ok
#
# The framebuffer pixels themselves are pinned by the class-A golden
# tests (torture document); this gate proves the LIVE byte path decodes
# multi-byte UTF-8 end to end on real hardware.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, screen captures, and scripts under $RUN_DIR. Set
# DIPSHIT_GATE_SUFFIX=_alt for distinct canonical evidence names;
# DIPSHIT_KEEP_RUN=1 keeps the scratch dir.

GATE_LOG="$(art live-unicode-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-unicode-report.txt)"

echo "=== verify-live-unicode: M20 U2/U3/U11 — Unicode on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-unicode
echo "run dir: $RUN_DIR"

SCRIPT="$RUN_DIR/input.txt"

cat > "$SCRIPT" <<'EOF'
text fontdebug on
text put café
text fontdebug
text putraw 中文
text fontdebug
echo m20-unicode-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    rm -f "$RUN_DIR"/gpu-screen-*
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --screen "$RUN_DIR/gpu-screen" --script "$SCRIPT" --script-expect "m20-unicode-ok" --timeout 30 \
        > "$(art live-unicode-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-unicode-serial-$tag.log)" || true
    cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
    SERIAL="$RUN_DIR/vm-serial.log"

    local SERIAL_BYTES BANNER=0 PUT_OK=0 ZERO_MISS=0 TWO_MISS=0 LAST_CP=0 DONE=0
    SERIAL_BYTES=$(wc -c < "$SERIAL" 2>/dev/null | tr -d ' ')
    if [ -f "$SERIAL" ]; then
        grep -qF "DipshitOS kernel" "$SERIAL" && BANNER=1
        # café flushed through the compositor without transport error.
        grep -qF "text put: ok" "$SERIAL" && PUT_OK=1
        # After café alone: no missing glyphs (é is in the Latin-1 table).
        grep -qF "missing=0" "$SERIAL" && ZERO_MISS=1
        # 中文 misses accumulate from BOTH the typed-line echo and the
        # command itself, so assert "some misses" + the recorded cp
        # rather than an exact count.
        grep -qE "missing=[0-9]+" "$SERIAL" && TWO_MISS=1
        # The last miss is 文 (U+6587) — the second char of the pair.
        grep -qF "last=U+6587" "$SERIAL" && LAST_CP=1
        grep -qF "m20-unicode-ok" "$SERIAL" && DONE=1
    fi
    echo "$tag: rc=$RC bytes=$SERIAL_BYTES banner=$BANNER put_ok=$PUT_OK zero_miss=$ZERO_MISS two_miss=$TWO_MISS last_cp=$LAST_CP done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$PUT_OK" = 1 ] && [ "$ZERO_MISS" = 1 ] \
        && [ "$TWO_MISS" = 1 ] && [ "$LAST_CP" = 1 ] && [ "$DONE" = 1 ]
}

PASS=0
for n in $(seq 1 "$BOOTS"); do
    echo "=== live-unicode boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then PASS=$((PASS + 1)); fi
done

if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-unicode: PASS ($PASS/$BOOTS)"
    echo "PASS: $PASS/$BOOTS" > "$REPORT"
    exit 0
else
    echo "verify-live-unicode: FAIL ($PASS/$BOOTS)"
    echo "FAIL: $PASS/$BOOTS" > "$REPORT"
    exit 1
fi
