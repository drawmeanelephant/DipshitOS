#!/usr/bin/env bash
#
# verify-live-glyphs.sh -- the MIRROR-REGRESSION TRIPWIRE (follow-on to the
# ScreenCaptureKit switch, 2026-08-12): the captured framebuffer is decoded
# against the kernel's OWN font8x8.zig glyph table (kernel/src/font8x8.zig),
# normalized from its documented LSB-left source rows, and the text must read
# FORWARD.
#
# Why: the milestone-six pixel gates (live-screen/live-text/live-roadpops)
# assert the evidence shows green-family glyphs over the dark background —
# they prove TEXT IS THERE but not that it reads the RIGHT WAY. The user
# reported "backwards text" while the decode said forward; the honest
# resolution is a gate that fails MECHANICALLY if the screen ever mirrors.
# The matcher (tools/decode-screen-glyphs.py) finds the green glyph grid
# (pitch + origin via a scored phase search), decodes the visible session
# in BOTH orientations, and reports the unknown-glyph counts:
#   - FORWARD decode of a correct screen: ~zero unknowns (measured 0/604);
#   - MIRRORED decode of the same screen: ~everything unknown (549/595) —
#     the mirror of 8x8 glyphs matches almost nothing in the table.
# So "forward unknowns ≈ 0 AND mirrored unknowns ≫ forward" is a
# mechanical mirror test. The decoded session text is also asserted to
# contain the boot banner's first word and the prompt — the semantic proof
# that the text is not just glyph-shaped but reads as words.
#
# The decoder ALSO decodes the Driving Award clock overlay (the window
# manager's amber title bar + "DRIVING AWARD" accent line on navy) in both
# orientations. Phase 2d asserts the clock title + body read FORWARD —
# covering the WINDOW-MANAGER path (G5's draw_string + blit_rect), which
# shares the forward glyph blit but uses a different color pair, so a
# mirror there would NOT trip the green-terminal matcher.
#
# Calibration (the matcher's header comment): the ScreenCaptureKit
# composited-window captures render the guest framebuffer with display
# smoothing; the matcher thresholds at the bright stroke core (g > 140,
# green-dominant), where the strokes sit at their exact ideal 2x positions
# (verified cell-by-cell on the 'D'), excluding the anti-aliased smear.
# The Phase-0 assertion below additionally REQUIRES the capture to be the
# ScreenCaptureKit composited window (not the cacheDisplay fallback), so
# the glyph decode is performed on the same pixels the operator sees.
#
# Honest bounds: (a) the decode is scored per-cell against the 95-glyph
# ASCII 0x20-0x7e table — the cursor block and a mid-present partial cell
# are legitimately "unknown", so the forward allowance is <= 2 cells; (b)
# byte-exact glyph shapes are the class A mocks' job (independent asymmetric
# C goldens in font8x8.zig, text.zig, and driving_award.zig); this gate proves
# the LIVE pixels read forward, mechanically and reproducibly.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): the boot attaches a
# private DiskImageKit stacked disk (read-only base + throwaway ASIF
# overlay), a private EFI var store, and writes its serial log and screen
# captures under $RUN_DIR before they are copied to the canonical evidence
# names. DIPSHIT_GATE_SUFFIX=_alt / DIPSHIT_KEEP_RUN=1 supported.
#
# Class B — Apple silicon + VZ only; boots real VMs.
#
# Usage:
#   bash tools/verify-live-glyphs.sh
#
# Evidence: artifacts/live-glyphs-gate.txt (full output),
# artifacts/live-glyphs-report.txt, "$(art live-glyphs-run.txt)" (runner),
# artifacts/gpu-screen-*s (the captures).
#
# Dependencies: python3 (stdlib only — zlib/struct, no PIL), the runner +
# disk image (built below), and Screen Recording permission for the SCK
# capture path.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-glyphs-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-glyphs-report.txt)"
RUNNER="host/vm-runner/.build/release/VMRunner"

echo "=== verify-live-glyphs: the mirror tripwire — the captured framebuffer decodes FORWARD against the font8x8 LSB-left source convention ==="

# 1. Build the runner + the disk image (the kernel carries text.zig + the
# Road Pops tee that renders the session on screen).
echo
echo "[1/3] building the runner + disk image"
swift build --package-path host/vm-runner --configuration release >/dev/null 2>&1
# The other live gates' convention: the fresh binary needs the
# com.apple.security.virtualization entitlement before it can boot a VM.
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
# Private scratch dir + pristine-boot overlay for EVERY boot.
gate_begin live-glyphs
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
zig build >/dev/null 2>&1
zig build image >/dev/null 2>&1

# 2. The scripted boot: a real terminal SESSION so the captured frame is
# full of words (banner + echo + uname + the tee report).
SCRIPT="$RUN_DIR/script.txt"
printf 'echo ROADPOPS\nuname\nroadpops\n' > "$SCRIPT"
rm -f "$RUN_DIR/vm-serial.log" "$RUN_DIR"/gpu-screen-*.png "$REPORT"

echo
echo "[2/3] live VZ run (scripted)"
set +e
"$RUNNER" "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" --screen "$RUN_DIR/gpu-screen" --script "$SCRIPT" \
    --expect "roadpops: armed target=fbtext" --timeout 30 \
    > "$(art live-glyphs-run.txt)" 2>&1
RC=$?
set -e
[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-glyphs-serial.log)" || true
for f in "$RUN_DIR"/gpu-screen-*.png; do [ -e "$f" ] && cp "$f" artifacts/ || true; done
echo "runner exit: $RC"
echo "--- runner output (roadpops/text lines) ---"
grep -E "roadpops:|text:|SUCCESS|FAILURE" "$(art live-glyphs-run.txt)" | head -20
if [ "$RC" -ne 0 ]; then
    echo "FAIL: runner did not complete successfully (exit $RC)"
    exit 1
fi

# 3. Assertions.
echo
echo "[3/3] asserting the serial seam + the glyph-level decode"

fail() { echo "FAIL: $1"; exit 1; }

# Phase 0 — the evidence path (the SCK enforcement shared with the other
# pixel gates): the decode must run on the COMPOSITED WINDOW pixels, not
# the cacheDisplay offscreen render.
grep -q "capture path: ScreenCaptureKit" "$(art live-glyphs-run.txt)" \
    || fail "pixel evidence did not come from ScreenCaptureKit (composited window) — Screen Recording permission missing or the SCK path broke"
if grep -q "capture path: cacheDisplay fallback" "$(art live-glyphs-run.txt)"; then
    fail "some captures fell back to cacheDisplay (offscreen render) — every capture must be the composited window"
fi

# Phase 1 — the shared-seam serial evidence (the session IS on screen).
grep -q "roadpops: armed target=fbtext" "$(art live-glyphs-serial.log)" || fail "the Road Pops tee was not armed with the framebuffer target"
grep -q "text: boot banner presented" "$(art live-glyphs-serial.log)" || fail "boot banner not presented (the tee's first present)"
grep -q "DipshitOS - AArch64 firmware-assisted kernel monitor" "$(art live-glyphs-serial.log)" || fail "serial transcript lost the banner (shared-seam regression)"

# Phase 2 — THE MIRROR TRIPWIRE: decode the captured PNG against the
# kernel's own LSB-left font table in both orientations and assert the text
# reads FORWARD after explicit source-to-screen normalization.
LATEST="$(ls -t artifacts/gpu-screen-*s 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
    fail "no gpu-screen PNG captured"
fi
echo "decoding $LATEST with tools/decode-screen-glyphs.py"
DECODE="$(python3 tools/decode-screen-glyphs.py "$LATEST")"
echo "$DECODE"

STATS="$(printf '%s\n' "$DECODE" | grep '^STATS ' || true)"
if [ -z "$STATS" ]; then
    fail "the decoder did not produce a STATS line — no glyph grid found in the capture"
fi
# STATS fwd_unknowns=N fwd_ink=M mir_unknowns=K mir_ink=L
fwd_u="$(printf '%s\n' "$STATS" | sed -n 's/.*fwd_unknowns=\([0-9-][0-9-]*\).*/\1/p')"
fwd_i="$(printf '%s\n' "$STATS" | sed -n 's/.*fwd_ink=\([0-9-][0-9-]*\).*/\1/p')"
mir_u="$(printf '%s\n' "$STATS" | sed -n 's/.*mir_unknowns=\([0-9-][0-9-]*\).*/\1/p')"
mir_i="$(printf '%s\n' "$STATS" | sed -n 's/.*mir_ink=\([0-9-][0-9-]*\).*/\1/p')"

# 2a. The forward decode must be essentially CLEAN: <= 2 unknown cells
# (the allowance is the cursor block + at most one mid-present partial
# cell — the measured clean session decodes 0/604). A mirrored screen
# pushes this into the hundreds.
if [ "$fwd_u" = "-1" ]; then
    fail "decoder could not find the glyph grid — blank or non-terminal frame"
fi
if [ "$fwd_u" -gt 2 ]; then
    fail "forward decode has $fwd_u unknown cells of $fwd_i ink — the text does not match the font8x8 table (mirrored? broken rendering?)"
fi
echo "forward decode: $fwd_u unknown cells of $fwd_i ink (allowance 2) — CLEAN"

# 2b. The mirrored decode must be MUCH worse — the whole point of the
# tripwire: if the screen were mirrored, the forward decode would be the
# garbage one and the mirrored decode would read clean. A mirrored screen
# makes mir_unknowns small and fwd_unknowns huge, which 2a already fails;
# this second leg proves the matcher can TELL the difference (the two
# orientations are distinguishable), so a "both-garbage" regression also
# fails.
if [ "$mir_u" -le $((fwd_u * 3 + 8)) ]; then
    fail "mirrored decode ($mir_u unknowns of $mir_i ink) is not decisively worse than forward ($fwd_u) — the matcher cannot discriminate orientation"
fi
echo "mirrored decode: $mir_u unknown cells of $mir_i ink — decisively worse (forward reads, mirror is garbage)"

# 2c. The semantic proof: the decoded session contains the boot banner's
# first word and the prompt — the text is not just glyph-shaped, it reads.
if ! printf '%s\n' "$DECODE" | grep -q "DipshitOS - AArch64"; then
    fail "the decoded session does not contain the boot banner line — the text does not read forward"
fi
if ! printf '%s\n' "$DECODE" | grep -q "dipshit>"; then
    fail "the decoded session does not contain the prompt — the terminal session did not render"
fi
echo "decoded session reads forward (banner + prompt present)"

# 2d. The window manager's clock overlay must ALSO read forward — the
# title ("clock", dark on amber) and the body ("DRIVING AWARD", amber on
# navy). These share G5's forward glyph blit but a different color pair,
# so a mirror in the WINDOW-MANAGER path (draw_string + blit_rect) would
# pass the green-terminal tripwire above yet fail here.
ct_fwd_u="$(printf '%s\n' "$STATS" | sed -n 's/.*clock_title_fwd_u=\([0-9-][0-9-]*\).*/\1/p')"
ct_mir_u="$(printf '%s\n' "$STATS" | sed -n 's/.*clock_title_mir_u=\([0-9-][0-9-]*\).*/\1/p')"
cb_fwd_u="$(printf '%s\n' "$STATS" | sed -n 's/.*clock_body_fwd_u=\([0-9-][0-9-]*\).*/\1/p')"
cb_mir_u="$(printf '%s\n' "$STATS" | sed -n 's/.*clock_body_mir_u=\([0-9-][0-9-]*\).*/\1/p')"
if [ -z "$ct_fwd_u" ] || [ -z "$ct_mir_u" ] || [ -z "$cb_fwd_u" ] || [ -z "$cb_mir_u" ]; then
    fail "decoder did not produce the clock-window STATS fields (clock_title/clock_body unknown counts)"
fi
if [ "$ct_fwd_u" -gt 2 ]; then
    fail "clock title forward decode has $ct_fwd_u unknown cells — the window-manager title does not read forward"
fi
if [ "$cb_fwd_u" -gt 2 ]; then
    fail "clock body forward decode has $cb_fwd_u unknown cells — the window-manager body does not read forward"
fi
if ! printf '%s\n' "$DECODE" | grep -q '^CLOCK_TITLE=clock$'; then
    fail "the decoded clock title is not 'clock' (got: $(printf '%s\n' "$DECODE" | grep '^CLOCK_TITLE=' || echo '<none>'))"
fi
if ! printf '%s\n' "$DECODE" | grep -q '^CLOCK_BODY=DRIVING AWARD$'; then
    fail "the decoded clock body is not 'DRIVING AWARD' (got: $(printf '%s\n' "$DECODE" | grep '^CLOCK_BODY=' || echo '<none>'))"
fi
if [ "$ct_mir_u" -lt 3 ]; then
    fail "clock title mirrored decode has only $ct_mir_u unknowns (of 5) — the matcher cannot tell the title is forward"
fi
if [ "$cb_mir_u" -lt 7 ]; then
    fail "clock body mirrored decode has only $cb_mir_u unknowns (of 13) — the matcher cannot tell the body is forward"
fi
echo "clock window decodes forward (title 'clock' + body 'DRIVING AWARD'; mirrored decode decisively worse: $ct_mir_u/5 and $cb_mir_u/13 unknowns)"

echo
echo "=== verify-live-glyphs: PASS (the captured framebuffer decodes FORWARD against the font8x8 LSB-left convention — mirror regression impossible to miss, terminal AND clock window) ==="
echo "evidence: "$(art live-glyphs-run.txt)", the per-run serial log, artifacts/gpu-screen-*s, tools/decode-screen-glyphs.py" | tee "$REPORT"
