#!/usr/bin/env bash
#
# verify-live-text-search.sh -- milestone-twenty card U3 class-B gate
# (march-m20 "Text search in apps", claim 8961).
#
# What is proven, LIVE on real VZ:
#   1. NOTEPAD.BIN (window auto-focused on open): the synthesized-keyboard
#      wall does not apply to the claim-9588 custom-virtio INPUT queue —
#      its kind-1 messages carry the HID modifier byte, so Ctrl+F and
#      Ctrl+G reach the FOCUSED USER WINDOW headlessly (no --display, no
#      NSEvent, no activation). The walk types a three-line document,
#      opens the M15 C6 find bar with Ctrl+F, searches "wor" and accepts
#      with Enter (the app reports hit 1/1 over serial), then opens the
#      M20-U3 Ctrl+G goto bar and jumps to line 2 (offset reported).
#   2. FILE.BIN: Ctrl+F narrows the /data listing in real time; every
#      keystroke applies the filter and reports shown/total over serial;
#      "txt" matches the DATA-volume text files.
#   3. The shell survives both walks: focus returns to the terminal via
#      the monitor's `dui focus 0` (serial input reaches the monitor
#      regardless of window focus) and the final echo markers run.
#
# The serial markers (`notepad: find 'wor' hit=1/1`,
# `notepad: goto line=2 offset=6`, `file: filter 'txt' shown=N total=M`)
# are guest-observed evidence; the match highlight itself is pinned by
# host unit tests (notepad/file_browser test modules).
#
# Run isolation (#523 item 2, claim 6637): private stacked disk + EFI
# vars + serial log per boot under $RUN_DIR. VIRELAI_GATE_SUFFIX for
# concurrent instances, VIRELAI_KEEP_RUN=1 to keep the scratch dir.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-text-search-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-text-search-report.txt)"

echo "=== verify-live-text-search: M20 U3 — NOTEPAD find/goto + FILE.BIN filter on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# The custom-virtio INPUT queue rides behind -DSPIKE (claims 9367/0680).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-text-search
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio "$@"
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-text-search-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

assert_serial() {
    # $1 = tag, $2 = expected marker
    grep -a -qF -- "$2" "$(art live-text-search-serial-$1.log)"
}

PASS=0

# --- boot A: NOTEPAD find bar + Ctrl+G goto line ----------------------------
echo "--- boot A: NOTEPAD Ctrl+F find + Ctrl+G goto-line ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'dui focus 0\necho m20-notepad-search-ok\n' > "$RUN_DIR/settle-A.txt"
# Types "hello\nworld\ntext" into the buffer, then Ctrl+F w-o-r Enter
# (hit 1/1), then Ctrl+G 2 Enter (line 2 starts at offset 6).
CHORDS_A="h,e,l,l,o,return,w,o,r,l,d,return,t,e,x,t,ctrl-f,w,o,r,return,ctrl-g,2,return"
if run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --input-chords "$CHORDS_A" --input-chords-after "notepad: ready" \
    --script2 "$RUN_DIR/settle-A.txt" --script2-after "notepad: goto line=2 offset=6" --script2-delay 2 \
    --script-expect "m20-notepad-search-ok" --timeout 150; then
    A_OK=1
    for m in \
        "notepad: ready" \
        "notepad: find 'wor' hit=1/1" \
        "notepad: goto line=2 offset=6" \
        "m20-notepad-search-ok"; do
        assert_serial A "$m" || { echo "boot A missing marker: $m"; A_OK=0; }
    done
else
    A_OK=0
fi
[ "$A_OK" = 1 ] && PASS=$((PASS + 1))

# --- boot B: FILE.BIN Ctrl+F filename filter ---------------------------------
echo "--- boot B: FILE.BIN Ctrl+F listing filter ---"
printf 'exec FILE.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui focus 0\necho m20-file-search-ok\n' > "$RUN_DIR/settle-B.txt"
# Each keystroke applies the filter; the final state narrows to *.TXT.
CHORDS_B="ctrl-f,t,x,t"
if run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --input-chords "$CHORDS_B" --input-chords-after "file: ready" \
    --script2 "$RUN_DIR/settle-B.txt" --script2-after "file: filter 'txt'" --script2-delay 2 \
    --script-expect "m20-file-search-ok" --timeout 150; then
    B_OK=1
    SER_B="$(art live-text-search-serial-B.log)"
    assert_serial B "file: ready" || { echo "boot B missing: file: ready"; B_OK=0; }
    # The final filter report: shown>=1 of total>=shown (the DATA volume
    # carries .TXT files on any pristine boot).
    grep -aEq "file: filter 'txt' shown=[1-9][0-9]* total=[0-9]+" "$SER_B" \
        || { echo "boot B missing: final txt filter report with shown>=1"; B_OK=0; }
    assert_serial B "m20-file-search-ok" || { echo "boot B missing: done marker"; B_OK=0; }
else
    B_OK=0
fi
[ "$B_OK" = 1 ] && PASS=$((PASS + 1))

echo "$REVISION branch=$BRANCH" > "$REPORT"
{
    echo "bootA(notepad find+goto)=$A_OK bootB(file filter)=$B_OK"
} >> "$REPORT"

if [ "$PASS" = 2 ]; then
    echo "verify-live-text-search: PASS (find hit ordinal, goto offset, filter accounting — all guest-observed)"
    echo "PASS: $PASS/2 boots" >> "$REPORT"
    exit 0
fi
echo "verify-live-text-search: FAIL ($PASS/2 boots)"
echo "FAIL: $PASS/2 boots" >> "$REPORT"
exit 1
