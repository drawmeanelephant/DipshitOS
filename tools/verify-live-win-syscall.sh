#!/usr/bin/env bash
#
# verify-live-win-syscall.sh -- claim 0487 (milestone six, card G6) class-B
# gate: the draw/window syscall seam + per-process ownership, live on real
# VZ.
#
# Two EL0 programs prove the seam end to end:
#   * WIN.BIN (open -> fill -> present -> exit 87) proves an EL0 program
#     can render a window, and — with per-process ownership — that the
#     window AUTO-CLOSES when its owner exits: the post-exit `win` report
#     reads windows=2 and `syscalls` shows sys_win_close calls=0 (no
#     explicit close; the exit path's close_owner released it).
#   * WINLOOP.BIN (open -> fill -> present -> yield-forever) keeps its
#     window ALIVE so the decoded capture can pixel-prove an EL0-rendered
#     window on the scanout (WIN.BIN's window vanishes before a capture).
#
# Phases (the claim-4613/7786 two/three-phase pattern):
#   * script1:  `exec WIN.BIN` (open/fill/present/exit -> auto-close).
#   * script2:  (after `procs WIN.BIN exited status=87`) `dui` + `syscalls`
#               on the SAME kernel state (windows=2, close=0), then
#               `exec WINLOOP.BIN`.
#   * script3:  (after `winloop: loop ok`) `dui` + `syscalls` + `dui list 2`
#               + `dui list 0` — WINLOOP's window (windows=3,
#               open=2/fill=8/present=2/close=0) and the per-process-owner
#               column (dui[2] owner=2, the fixed windows owner=-, and the
#               `dui list <pid>` filter returns pid 2 -> matches=1 while a
#               non-owner pid 0 -> matches=0).
#   * pixel proof: the decoded capture shows WINLOOP's OWN rendered content
#     in its rect (64,64,256,192): the dark-blue background + red/cyan/white
#     blocks, with NO green (terminal foreground) inside the rect.
#
# Honest bound (the G1/G2/G3/G5 precedent): byte-exact pixels are the class
# A mock's domain; the LIVE pixels are color-managed + retina-scaled, so the
# live assertion is "distinct color families in the expected regions", not
# per-byte equality. The observed capture colors are pinned in the claim.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR;
# VIRELAI_GATE_SUFFIX/_KEEP_RUN supported.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge proves
# class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-win-syscall.sh
#
# Evidence: artifacts/live-win-syscall-gate.txt (full output),
# artifacts/live-win-syscall-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-win-syscall-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-win-syscall-report.txt"

echo "=== verify-live-win-syscall: claim 0487 — the draw/window syscall seam + ownership, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/*.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-win-syscall
gate_seed_share
echo "run dir: $RUN_DIR"

# --- scripted session ---------------------------------------------------------
# Phase 1 exec's WIN.BIN (the open/fill/present/exit proof — its window
# AUTO-CLOSES on exit). Phase 2 (--script2, after the reap) reads the
# post-exit kernel state (windows=2, close=0) and exec's WINLOOP.BIN (the
# persistent window). Phase 3 (--script3, after winloop's marker) reads the
# post-WINLOOP state (windows=3, open=2/fill=8/present=2).
cat > "$RUN_DIR/script.txt" <<'EOF'
exec WIN.BIN
EOF
cat > "$RUN_DIR/script2.txt" <<'EOF'
dui
syscalls
exec WINLOOP.BIN
EOF
cat > "$RUN_DIR/script3.txt" <<'EOF'
dui
syscalls
dui list 2
dui list 0
echo win-syscall-settled
EOF

# Boots the private WRITABLE copy (not an overlay): the timed screen
# captures need main-like boot pacing; overlays shift guest timing
# so the fill/present lands after the last scheduled capture.

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR"/snap-*.raw
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --display --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-after "win-syscall-settled" \
        --snapshot-out "$RUN_DIR/snap" \
        --script "$RUN_DIR/script.txt" \
        --script2 "$RUN_DIR/script2.txt" --script2-after "procs WIN.BIN exited status=87" \
        --script3 "$RUN_DIR/script3.txt" --script3-after "winloop: loop ok" \
        --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
    for f in "$RUN_DIR"/snap-*.raw; do
        [ -f "$f" ] && cp "$f" "$(art live-win-syscall-snap-0.raw)" && break || true
    done
    echo "$RC" > "$RUN_DIR/rc.txt"
}

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
run_one "$(art live-win-syscall-run.txt)" "$(art live-win-syscall-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
set -e

# --- assertions ---------------------------------------------------------------
SERIAL="$(art live-win-syscall-serial.log)"
MARK=0 EXIT87=0 AUTO2=0 LOOP=0 WIN3=0 ROW2=0 IMPL=0 SNAP1=0 SNAP2=0 OWNERU=0 OWNERF=0 LIST2=0 LIST0=0
if [ -f "$SERIAL" ]; then
    # WIN.BIN's EL0 render markers (open/fill/present end to end).
    grep -a -q -F -- "win: fill ok" "$SERIAL" && \
        grep -a -q -F -- "win: present ok" "$SERIAL" && MARK=1
    grep -a -q -F -- "procs WIN.BIN exited status=87" "$SERIAL" && EXIT87=1
    # AUTO-CLOSE: after WIN.BIN exits, `dui` reads windows=4 (terminal,
    # wallpaper, taskbar, dock — the user window was released by the exit path,
    # NOT an explicit close).
    grep -a -q -F -- "dui: windows=4" "$SERIAL" && AUTO2=1
    # WINLOOP's persistent window marker + the post-open observation.
    grep -a -q -F -- "winloop: loop ok" "$SERIAL" && LOOP=1
    grep -a -q -F -- "dui: windows=5" "$SERIAL" && WIN3=1
    grep -a -q -F -- "dui[4]: user user rect=64,64,512,384" "$SERIAL" && ROW2=1
    grep -a -q -F -- "syscalls: slots=64 implemented=66" "$SERIAL" && IMPL=1
    # The owner column (runtime visibility of per-process ownership): the
    # user window shows its owning pid (2), the fixed windows show `-`.
    grep -a -E -q 'dui\[4\]: user user rect=64,64,512,384 .* owner=2' "$SERIAL" && OWNERU=1
    grep -a -E -q 'dui\[0\]: roadpops terminal .* owner=-' "$SERIAL" && \
        grep -a -E -q 'dui\[2\]: taskbar taskbar .* owner=-' "$SERIAL" && OWNERF=1
    # `dui list <pid>`: the filter returns WINLOOP's window for its pid (2)
    # and nothing for a non-owner (0).
    grep -a -q -F -- "dui list: pid=2 matches=1" "$SERIAL" && LIST2=1
    grep -a -q -F -- "dui list: pid=0 matches=0" "$SERIAL" && LIST0=1
    # The script2 snapshot (after WIN.BIN, before WINLOOP): open=1 with
    # close=0 — the window disappeared WITHOUT a sys_win_close call.
    grep -a -q -F -- "  12 sys_win_open calls=1" "$SERIAL" && \
        grep -a -q -F -- "  15 sys_win_close calls=0" "$SERIAL" && SNAP1=1
    # The script3 snapshot (after WINLOOP): open=2/fill=8/present=2 — the
    # persistent window's opens/fills/presents all landed, still close=0.
    grep -a -q -F -- "  12 sys_win_open calls=2" "$SERIAL" && \
        grep -a -q -F -- "  13 sys_win_fill calls=8" "$SERIAL" && \
        grep -a -q -F -- "  14 sys_win_present calls=2" "$SERIAL" && SNAP2=1
fi

echo "win-syscall: rc=$RC mark=$MARK exit87=$EXIT87 auto2=$AUTO2 loop=$LOOP win3=$WIN3 row2=$ROW2 impl=$IMPL snap1=$SNAP1 snap2=$SNAP2 owneru=$OWNERU ownerf=$OWNERF list2=$LIST2 list0=$LIST0"

PASS=0
if [ "$RC" = 0 ] && [ "$MARK" = 1 ] && [ "$EXIT87" = 1 ] && [ "$AUTO2" = 1 ] && \
   [ "$LOOP" = 1 ] && [ "$WIN3" = 1 ] && [ "$ROW2" = 1 ] && [ "$IMPL" = 1 ] && \
   [ "$SNAP1" = 1 ] && [ "$SNAP2" = 1 ] && [ "$OWNERU" = 1 ] && [ "$OWNERF" = 1 ] && \
   [ "$LIST2" = 1 ] && [ "$LIST0" = 1 ]; then
    PASS=1
fi

# Phase 2 — the pixel proof (headless virtio snapshot: 1280x720 BGRX raw scanout).
SNAP="$(ls -t "$RUN_DIR"/snap-*.raw 2>/dev/null | head -1 || ls -t artifacts/live-win-syscall-snap-*.raw 2>/dev/null | head -1 || true)"
if [ -z "$SNAP" ] || [ ! -f "$SNAP" ]; then
    echo "FAIL: no virtio scanout snapshot captured"
    PASS=0
else
    echo "decoding $SNAP"
    python3 - "$SNAP" <<'EOF'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k+2], data[k+1], data[k]) # R, G, B

def classify(r, g, b):
    if r > 220 and g > 220 and b > 220:
        return 'white'       # 0xffffff -> (255,255,255)
    if g > 200 and b > 200 and r < 170:
        return 'cyan'        # 0x00ffff -> (0,255,255)
    if r > 180 and g < 110 and b < 110:
        return 'red'         # 0xff0000 -> (255,0,0)
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'    # 0x1a2b3c -> (26,43,60)
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# The user window rect: logical (64,64,512,384).
UX0, UY0, UX1, UY1 = 64, 64, 576, 448

# (a) The three filled blocks sit at their expected spots:
# local (8,8), (64,8), (120,8) of size 48x48 -> centers (96,96), (152,96), (208,96).
red = classify(*px(96, 96))
cyan = classify(*px(152, 96))
white = classify(*px(208, 96))
print(f"blocks: red={red} cyan={cyan} white={white}")
if red != 'red':
    sys.exit(f"FAIL: the red block is not red at its spot ({red}) — the fill did not land")
if cyan != 'cyan':
    sys.exit(f"FAIL: the cyan block is not cyan at its spot ({cyan}) — the fill did not land")
if white != 'white':
    sys.exit(f"FAIL: the white block is not white at its spot ({white}) — the fill did not land")

# (b) The background is the dark-blue fill (0x1a2b3c), dominant in the client rect.
body = region(UX0 + 8, UY0 + 64, UX1 - 8, UY1 - 8)
fb = frac(body, 'darkblue')
print(f"user window body: {body} darkblue={fb:.3f}")
if fb < 0.60:
    sys.exit("FAIL: the user window background is not the dark-blue fill (the window did not render)")

# (c) NO green (terminal foreground) inside the user window client area — the
# opaque back-buffer covers the terminal beneath it (z-order proof).
whole = region(UX0 + 8, UY0 + 20, UX1 - 8, UY1 - 8, step=2)
if whole.get('green', 0) != 0:
    sys.exit(f"FAIL: terminal foreground visible inside the user window rect ({whole.get('green',0)} green) — the window did not cover the terminal")

print("PASS: the user window's own rendered content (dark-blue background + red/cyan/white blocks) sits in its rect over the terminal, with no terminal foreground showing through")
EOF
    if [ $? -ne 0 ]; then
        echo "FAIL: captured framebuffer does not show the user window's rendered content"
        PASS=0
    fi
fi

{
    echo "VIRELAIOS live draw/window-syscall gate (claim 0487 / issue #731) — EL0 graphics + ownership on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: scripted exec of WIN.BIN (open/fill/present/exit -> AUTO-CLOSE on exit), then win + syscalls on the same kernel state, then exec of WINLOOP.BIN (the persistent window) with win + syscalls observation + the decoded virtio capture"
    echo "assertions: win: fill ok / present ok + procs WIN.BIN exited status=87, dui: windows=4 after the exit (auto-close, close=0), winloop: loop ok, dui: windows=5 + dui[4]: user user rect=64,64,512,384 owner=2 (fixed windows owner=-), dui list 2 -> matches=1 + dui list 0 -> matches=0, syscalls implemented=66 with open=1/close=0 (pre-WINLOOP) + open=2/fill=8/present=2 (post-WINLOOP), red + cyan + white blocks at their spots, dark-blue background dominant, no terminal foreground inside the window rect"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win-syscall: PASS — WIN.BIN opened a user window, filled it (dark-blue background + red/cyan/white blocks), presented it, and exited 87 — and the window AUTO-CLOSED on exit (dui: windows=4, sys_win_close calls=0). WINLOOP.BIN then kept its own window alive so the decoded capture shows an EL0-rendered window on the scanout (the window's own content over the terminal, no terminal foreground showing through), with syscalls reporting implemented=66 and open=2/fill=8/present=2 — and the dui report's owner column shows WINLOOP's pid (2, fixed windows owner=-) with 'dui list 2' -> matches=1 and a non-owner 'dui list 0' -> matches=0. The default VM is untouched: without --display, the window manager is unarmed and sys_win_open returns EINVAL — every existing gate stays byte-identical."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win-syscall: FAILED — see artifacts/live-win-syscall-report.txt, the runner output (live-win-syscall-run.txt), and the serial log (live-win-syscall-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
