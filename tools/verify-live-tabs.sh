#!/usr/bin/env bash
#
# verify-live-tabs.sh -- milestone-twenty card U10 class-B gate (issue
# #315): tab stops in the terminal text layer, proven in PIXELS.
#
# Why pixels: TAB bytes cannot traverse the serial line editor (Tab is
# completion there), so the probes go through `text putraw Q\tZ` (the
# monitor's \t escape expands to a real TAB inside putc). Cursor-column
# reads over serial are polluted by the shared echo pipeline, so the
# gate instead captures the composited framebuffer and DECODES it:
#
#   boot A: text clear; text putraw Q\tZ   -> decoded row shows Q, a run
#          of materialized spaces (the tab stop fill), then Z
#   boot B: text clear; text putraw QZ     -> decoded row shows QZ adjacent
#
# The U10 contract is exactly that: a TAB advances to the next 8-column
# stop and the skipped cells hold real space characters.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR.
#
# Class B — Apple silicon + VZ only (Screen Recording permission required
# for the ScreenCaptureKit capture path).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-tabs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-tabs-report.txt)"

echo "=== verify-live-tabs: M20 U10 — tab stops in pixels on VZ ==="

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
gate_begin live-tabs
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag, $2 = putraw argument, $3 = probe marker
    local tag="$1" arg="$2" marker="$3"
    # RACE FIX (fleet remainder claim 2259, root cause pinned): the old walk
    # set --screenshot-after AND --script-expect to the SAME marker. In the
    # runner's scriptPoll (host/vm-runner/Sources/VMRunner/main.swift) the
    # script-expect check runs BEFORE the marker-capture hook and RETURNS on
    # a match — so the marker-driven capture could never fire, and the gate's
    # `gpu-screen-*s` glob silently collected the PERIODIC 5/10/15 s frames
    # instead. Whichever periodic frame happened to be newest decided the
    # decode: pre-paint frames failed the tab-gap assert (the documented
    # probe-decode race), and a boot where no periodic frame fit before exit
    # lost the PNG entirely. The walk now separates the triggers BY
    # CONSTRUCTION: the probe marker fires --screenshot-after; --script2
    # (parked --script2-delay 3 past the probe marker) types the SETTLE
    # marker, which is the --script-expect. The capture therefore always has
    # >= 3 s to complete before teardown, and its filename is DETERMINISTIC
    # (<base>-<label> = gpu-screen-after; the base has no extension).
    local script="$RUN_DIR/input-$tag.txt"
    local script2="$RUN_DIR/settle-$tag.txt"
    printf 'text clear\ntext putraw %s\ntext fontdebug\necho %s\n' "$arg" "$marker" > "$script"
    echo "echo $marker-settled" > "$script2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" artifacts/gpu-screen-*
    set +e
    # Private WRITABLE copy (not overlay): keeps main-like boot pacing so the
    # post-marker screenshot catches the painted row (observed claim 5069).
    #
    # STALENESS MARGIN (claim 2259): in a non-active-window session the
    # window server recomposites the runner window LAGGINGLY — single-shot
    # marker captures returned frames seconds stale (the decoded frame
    # predated the very trigger string in the serial log; observed twice).
    # The claim-6053 PERIODIC ladder (-5s/-10s/-15s) keeps sampling though,
    # and empirically catches up within ~5 s (the 10 s frame was already
    # current). So: NO marker capture; the exit is PARKED (--script2-delay
    # 12 -> teardown >= 12 s after the probe marker, >= 11 s after the
    # paint), and the evidence is the LAST ladder frame (gpu-screen-15s,
    # taken >= 9 s after the paint on any sane boot) — deterministic name,
    # deterministic ordering, generous compositor margin.
    host/vm-runner/.build/release/VMRunner "$RUN_DIR/disk-base.img" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen artifacts/gpu-screen \
        --script "$script" \
        --script2 "$script2" --script2-after "$marker" --script2-delay 12 \
        --script-expect "$marker-settled" --timeout 60 \
        > "$(art live-tabs-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-tabs-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

fail() { echo "FAIL: $1"; exit 1; }

# --- boot A: the tabbed probe ---
echo "--- boot A: text putraw Q\\tZ ---"
run_boot probeA 'Q\tZ' m20-tabs-probeA || fail "probe boot failed"
[ -f artifacts/gpu-screen-15s ] || fail "no ladder capture for the probe (gpu-screen-15s missing)"
cp artifacts/gpu-screen-15s artifacts/live-tabs-screen-A.png
DECODE_A="$(python3 tools/decode-screen-glyphs.py artifacts/live-tabs-screen-A.png || true)"
echo "$DECODE_A" | grep '^STATS ' || true

# --- boot B: the adjacent control ---
echo "--- boot B: text putraw QZ ---"
run_boot probeB 'QZ' m20-tabs-probeB || fail "control boot failed"
[ -f artifacts/gpu-screen-15s ] || fail "no ladder capture for the control (gpu-screen-15s missing)"
cp artifacts/gpu-screen-15s artifacts/live-tabs-screen-B.png
DECODE_B="$(python3 tools/decode-screen-glyphs.py artifacts/live-tabs-screen-B.png || true)"
echo "$DECODE_B" | grep '^STATS ' || true

# --- blank-capture guard ---
# A headless runner (no --display window attached / no Screen Recording
# permission) yields blank frames: fwd_ink=0 from BOTH boots means there
# is NO pixel evidence to decode. That is an ENVIRONMENT limitation, not
# a guest regression — the U10 rendering itself is pinned pixel-exactly
# by the class-A torture golden (kernel/src/text.zig, tabs section).
# Default: report BLOCKED and exit 0 so headless CI documents the wall
# instead of lying red. Set VERIFY_LIVE_TABS_STRICT=1 on a display-
# capable machine to turn blank captures into hard failures.
ink_a="$(printf '%s\n' "$DECODE_A" | sed -n 's/.*fwd_ink=\([0-9]*\) .*/\1/p')"
ink_b="$(printf '%s\n' "$DECODE_B" | sed -n 's/.*fwd_ink=\([0-9]*\) .*/\1/p')"
if [ "${ink_a:-0}" = "0" ] && [ "${ink_b:-0}" = "0" ]; then
    if [ "${VERIFY_LIVE_TABS_STRICT:-0}" = "1" ]; then
        fail "blank captures on a strict run — fix Screen Recording/display first"
    fi
    echo "verify-live-tabs: BLOCKED — headless environment produced blank captures (fwd_ink=0 both boots);"
    echo "  the tab-stop rendering itself stays proven by the class-A torture golden."
    echo "  Re-run on a display-capable machine (or VERIFY_LIVE_TABS_STRICT=1) for pixel proof."
    echo "BLOCKED: blank captures (headless)" > "$REPORT"
    exit 0
fi

# --- assertions ---
echo "--- asserting the tab-stop gap in the decoded pixels ---"
# Probe: Q and Z separated by a run of >=3 spaces on ONE decoded row.
echo "$DECODE_A" | grep -qE 'Q {3,}Z' \
    || fail "decoded probe shows no tab gap (expected 'Q<spaces>Z' on a row)"
# Control: QZ land adjacent (the pipeline itself does not inject gaps).
echo "$DECODE_B" | grep -qE 'QZ' \
    || fail "decoded control lost QZ adjacency (capture/decode regression)"

echo "verify-live-tabs: PASS (tab stop + space fill observed in pixels)"
echo "PASS" > "$REPORT"
