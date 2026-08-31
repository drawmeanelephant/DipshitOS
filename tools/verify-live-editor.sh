#!/usr/bin/env bash
#
# verify-live-editor.sh -- M23 E2-E5 class-B gate:
# undo/redo, goto-line, multi-file tabs on real VZ hardware.
#
# Mechanism: boots the production image, execs EDIT.BIN from the monitor,
# waits for the app to be ready, sends Ctrl chords to exercise the new
# features, and asserts the serial markers prove they happened.
#
# The walk:
#   exec EDIT.BIN                          -> launch editor
#   (wait for edit: ready)                  -> app event loop running
#   Ctrl+T                                  -> open new tab (E4)
#   (assert edit: tab-open)                -> tab created
#   Ctrl+Z                                  -> undo (E2)
#   (assert edit: undo)                    -> undo happened
#   Ctrl+G                                  -> open goto prompt (E3)
#   (assert edit: goto-open)               -> goto prompt opened
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-editor.sh
#
# Evidence saved under artifacts/: live-editor-gate.txt,
# live-editor-report.txt, live-editor-run.txt, live-editor-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-editor-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-editor-report.txt)"

echo "=== verify-live-editor: M23 E2-E5 — undo, goto, tabs on VZ, $BOOTS boot(s) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# The SPIKE build (macOS 27 SDK types) so chords can ride the claim-9588
# custom-virtio INPUT queue: no VZ view, no window activation, no #179
# synthesized-keyboard drop (the editor needs --display for the GPU, but the
# VZ view is never key in a scripted agent session).
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-editor
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

# --- phase 1: launch EDIT.BIN from the monitor ------------------------------
cat > "$SCRIPT" <<'EOF'
exec EDIT.BIN
EOF

# --- phase 2: exercise undo, line numbers toggle, search, replace, delete line,
# command palette, recent files, theme cycle, bookmark, multi-cursor, file tree, save, tab, goto
# Each chord rides the custom-virtio INPUT queue headless-safe.
INPUT_CHORDS="f,n,space,m,a,i,n,space,m,a,i,n,ctrl-d,X,Y,ctrl-z,ctrl-l,ctrl-f,escape,ctrl-h,escape,ctrl-shift-d,ctrl-shift-p,escape,ctrl-r,escape,ctrl-shift-t,ctrl-b,ctrl-shift-f,return,ctrl-s,ctrl-t,ctrl-g"

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$(art editor-screen)" \
        --via-virtio \
        --script "$SCRIPT" \
        --input-chords "$INPUT_CHORDS" \
        --input-chords-after "edit: ready" \
        --script-expect "edit: goto-open" \
        --timeout 45 \
        > "$(art live-editor-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-editor-serial-$tag.log)" || true
    local SER="$(art live-editor-serial-$tag.log)"

    local SERIAL_BYTES=0 BANNER=0 EDIT_READY=0 TAB_OPEN=0 UNDO=0 GOTO_OPEN=0
    local TOGGLE_LINES=0 FIND_OPEN=0 REPLACE_OPEN=0 DELETE_LINE=0
    local PALETTE_OPEN=0 RECENT_OPEN=0 THEME_CYCLE=0 BOOKMARK_TOGGLE=0 MULTI_CURSOR=0 TREE_TOGGLE=0 TREE_OPEN=0 SAVE_OK=0
    if [ -f "$SER" ]; then
        SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "edit: ready" "$SER" && EDIT_READY=1
        grep -qF -- "edit: undo" "$SER" && UNDO=1
        grep -qF -- "edit: toggle-lines" "$SER" && TOGGLE_LINES=1
        grep -qF -- "edit: find-open" "$SER" && FIND_OPEN=1
        grep -qF -- "edit: replace-open" "$SER" && REPLACE_OPEN=1
        grep -qF -- "edit: delete-line" "$SER" && DELETE_LINE=1
        grep -qF -- "edit: palette-open" "$SER" && PALETTE_OPEN=1
        grep -qF -- "edit: recent-open" "$SER" && RECENT_OPEN=1
        grep -qF -- "edit: theme-cycle" "$SER" && THEME_CYCLE=1
        grep -qF -- "edit: bookmark-toggle" "$SER" && BOOKMARK_TOGGLE=1
        grep -qF -- "edit: multi-cursor" "$SER" && MULTI_CURSOR=1
        grep -qF -- "edit: tree-toggle" "$SER" && TREE_TOGGLE=1
        grep -qF -- "edit: tree-open-ok" "$SER" && TREE_OPEN=1
        grep -qF -- "edit: save-ok" "$SER" && SAVE_OK=1
        grep -qF -- "edit: tab-open" "$SER" && TAB_OPEN=1
        grep -qF -- "edit: goto-open" "$SER" && GOTO_OPEN=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY undo=$UNDO lines=$TOGGLE_LINES find=$FIND_OPEN repl=$REPLACE_OPEN del=$DELETE_LINE pal=$PALETTE_OPEN rec=$RECENT_OPEN theme=$THEME_CYCLE bmk=$BOOKMARK_TOGGLE cur=$MULTI_CURSOR tree=$TREE_TOGGLE topen=$TREE_OPEN save=$SAVE_OK tab=$TAB_OPEN goto=$GOTO_OPEN"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER edit-ready=$EDIT_READY undo=$UNDO lines=$TOGGLE_LINES find=$FIND_OPEN repl=$REPLACE_OPEN del=$DELETE_LINE pal=$PALETTE_OPEN rec=$RECENT_OPEN theme=$THEME_CYCLE bmk=$BOOKMARK_TOGGLE cur=$MULTI_CURSOR tree=$TREE_TOGGLE topen=$TREE_OPEN save=$SAVE_OK tab=$TAB_OPEN goto=$GOTO_OPEN"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$EDIT_READY" = 1 ] && \
    [ "$UNDO" = 1 ] && [ "$TOGGLE_LINES" = 1 ] && [ "$FIND_OPEN" = 1 ] && \
    [ "$REPLACE_OPEN" = 1 ] && [ "$DELETE_LINE" = 1 ] && [ "$PALETTE_OPEN" = 1 ] && \
    [ "$RECENT_OPEN" = 1 ] && [ "$THEME_CYCLE" = 1 ] && [ "$BOOKMARK_TOGGLE" = 1 ] && \
    [ "$MULTI_CURSOR" = 1 ] && [ "$TREE_TOGGLE" = 1 ] && [ "$TREE_OPEN" = 1 ] && \
    [ "$SAVE_OK" = 1 ] && [ "$TAB_OPEN" = 1 ] && [ "$GOTO_OPEN" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live-editor gate (Milestone 23 complete E1-E25) — undo, search, replace, autoindent, brackets, lines, delete-line, palette, recents, themes, bookmarks, multi-cursor, tree, save, goto, tabs on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "phase 1: exec EDIT.BIN from monitor"
    echo "phase 2: input chords via custom-virtio input queue"
    echo "assertions: edit: ready, undo, toggle-lines, find-open, replace-open, delete-line, palette-open, recent-open, theme-cycle, bookmark-toggle, multi-cursor, tree-toggle, tree-open-ok, save-ok, tab-open, goto-open"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-editor boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-editor: PASS — undo (Ctrl+Z), goto-line (Ctrl+G), multi-file tabs (Ctrl+T) serial markers observed ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-editor: FAILED — $PASS/$BOOTS boot(s) passed; see artifacts/live-editor-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
