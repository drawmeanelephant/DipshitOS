#!/usr/bin/env bash
#
# verify-live-tabs.sh -- milestone-twenty card U5 class-B gate
# (march-m20 "Monospace rendering", Lane C issue #315, claim 8961).
#
# Why pixels: TAB bytes cannot traverse the serial line editor (Tab is
# completion there), so the probes go through `text putraw` and the proof
# is the DECODED SCANOUT.
#
# SEAM REGRESSION FOUND AND ROUTED AROUND (claim 8961, 2026-08-25): the
# Lane C `\t` escape inside putraw (monitor.zig "M20-U10 gate seam") is
# DEAD on current main — the M19 P5/P6 word tokenizer unescapes an
# UNQUOTED `\t` to a bare `t` before cmd_text ever sees it (its own
# backslash conversion can no longer fire). text.zig's tab rendering
# itself is intact and host-pinned. The gate therefore passes a REAL TAB
# through the tokenizer's DOUBLE-QUOTE escape (`"\t"` -> 0x09), which the
# monitor forwards into putc directly:
#
#   boot A: text putraw "AAAAAAAB\tZ" -> 8 cells of ink, TAB advances
#          from stop 8 to stop 16 materializing eight spaces, Z at col 16
#   boot B: text putraw "AAAAAAAABZ"  -> control: ink then Z ADJACENT
#
# DOCK BOUNDS (root cause corrected, claim 8961): the composed scanout
# carries the M21/M27 vertical dock at x=0..23 — the terminal's first
# THREE glyph columns are occluded chrome on every row. This is REAL
# pixel absence (the fleet log's "decoder grid alignment" hypothesis was
# wrong; see decode-screen-glyphs.py --raw docstring). Probes lead with
# seven/eight A's so every asserted glyph sits right of the dock:
# boot A decodes as three hidden blanks + AAAA + B + eight tab-fill
# spaces + Z; boot B as three hidden blanks + AAAAA + BZ adjacent.
#
# Evidence channel (claim 8961 — replaces the old ScreenCaptureKit ladder,
# red-on-main per the fleet-remainder investigation): --snapshot-after
# fires ONE claim-0680 kind-4 request and the guest streams its composed
# scanout over custom-virtio queue 4 into a byte-exact raw BGRX file.
# No ScreenCaptureKit, no Screen Recording TCC permission, no activation
# wall, and NO GRID SEARCH in the decoder — tools/decode-screen-glyphs.py
# --raw decodes at the kernel's fixed text grid (origin 0,0, 8px cells),
# which is also the fix for the leading-glyph-loss decode bug (`dipshit>`
# decoding as `shit>`) that hid every probe row from the old gate.
#
# Run isolation (#523 item 2, claim 6637): private stacked disk + EFI
# vars + serial log + snapshot file per boot under $RUN_DIR.
# DIPSHIT_GATE_SUFFIX for concurrent instances, DIPSHIT_KEEP_RUN=1 to
# keep the scratch dir.
#
# Class B — Apple silicon + VZ only.

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

echo "=== verify-live-tabs: M20 U5 — tab stops in guest-streamed pixels on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-tabs
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag, $2 = putraw argument, $3 = probe marker.
    # Trigger separation BY CONSTRUCTION (fleet claim 2259 lesson), tuned
    # for the kind-4 stream (claim 0680): paint first, THEN three staged
    # markers each 25 s apart —
    #   probe marker (serial, right after putraw)
    #   -> --script2 parks 25 s past it, then types "<probe>-settled"
    #      -> "<probe>-settled" fires the SNAPSHOT REQUEST (the scanout
    #         is long-since composited; OBSERVED: a request keyed on the
    #         probe marker itself streamed a frame from BEFORE the paint
    #         — the guest services the kind-4 request against whatever
    #         composite state exists at enqueue time, so the trigger must
    #         lag the paint by construction)
    #   -> --script3 parks 25 s past settled (>= the ~113-chunk stream),
    #      then types "<probe>-done", which --script-expect waits on.
    local tag="$1" arg="$2" marker="$3"
    local script="$RUN_DIR/input-$tag.txt"
    local script2="$RUN_DIR/settle-$tag.txt"
    local script3="$RUN_DIR/done-$tag.txt"
    printf 'text clear\ntext putraw %s\necho %s\n' "$arg" "$marker" > "$script"
    echo "echo $marker-settled" > "$script2"
    echo "echo $marker-done" > "$script3"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-after "$marker-settled" --snapshot-out "$RUN_DIR/snap-$tag" \
        --script "$script" \
        --script2 "$script2" --script2-after "$marker" --script2-delay 25 \
        --script3 "$script3" --script3-after "$marker-settled" --script3-delay 25 \
        --script-expect "$marker-done" --timeout 150 \
        > "$(art live-tabs-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-tabs-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

decode_probe() {
    # $1 = tag -> echoes the decoded frame; fails if the snapshot is
    # missing or not a full 1280x720x4 frame.
    local tag="$1"
    local SNAP="$(ls "$RUN_DIR"/snap-$tag-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$SNAP" ] || { echo "FAIL: no snapshot streamed for boot $tag"; return 1; }
    cp "$SNAP" "$(art live-tabs-screen-$tag.raw)"
    python3 tools/decode-screen-glyphs.py --raw 1280 720 "$SNAP"
}

fail() { echo "FAIL: $1"; exit 1; }

# --- boot A: the tabbed probe -------------------------------------------------
echo "--- boot A: text putraw \"AAAAAAAB\\tZ\" (tab from stop 8 to stop 16) ---"
run_boot A '"AAAAAAAB\tZ"' m20-tabs-probeA || fail "probe boot failed"
DECODE_A="$(decode_probe A)" || exit 1
printf '%s\n' "$DECODE_A" | grep '^STATS_RAW ' || true

# --- boot B: the adjacent control ----------------------------------------------
echo "--- boot B: text putraw \"AAAAAAAABZ\" (no tab — Z adjacent) ---"
run_boot B '"AAAAAAAABZ"' m20-tabs-probeB || fail "control boot failed"
DECODE_B="$(decode_probe B)" || exit 1
printf '%s\n' "$DECODE_B" | grep '^STATS_RAW ' || true

# --- assertions ------------------------------------------------------------------
echo "--- asserting the tab-stop gap in the decoded pixels ---"
# Probe: 7 A's from col 0 (first three under the dock), B at col 7, TAB
# materializes cols 8..15 as spaces, Z lands exactly on the col-16 stop,
# then the monitor's own reply follows at col 17.
echo "$DECODE_A" | grep -qE '^ {3}AAAAB {8}Ztext put: ok$' \
    || fail "decoded probe shows no exact tab-stop advance (expected AAAA + B + eight fill cells + Z + reply on one row)"
# Control: no TAB — Z lands immediately after the ink, adjacent
# (eight A's from col 0: three hidden under the dock, five visible).
echo "$DECODE_B" | grep -qE '^ {3}AAAAABZtext put: ok$' \
    || fail "decoded control lost adjacency (expected AAAA + BZ + reply on one row)"
# Decoder sanity on BOTH frames: crisp monospace decode — almost no cell
# in the whole frame fails to match a font glyph.
unk_a="$(printf '%s\n' "$DECODE_A" | sed -n 's/.*fwd_unknowns=\([0-9]*\).*/\1/p')"
unk_b="$(printf '%s\n' "$DECODE_B" | sed -n 's/.*fwd_unknowns=\([0-9]*\).*/\1/p')"
[ "${unk_a:-99}" -le 2 ] || fail "boot A decoded with $unk_a unknown cells (expected a crisp monospace frame)"
[ "${unk_b:-99}" -le 2 ] || fail "boot B decoded with $unk_b unknown cells (expected a crisp monospace frame)"

echo "verify-live-tabs: PASS (tab stop + space fill observed in guest-streamed pixels)"
echo "PASS" > "$REPORT"
