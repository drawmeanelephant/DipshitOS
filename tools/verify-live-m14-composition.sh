#!/usr/bin/env bash
#
# verify-live-m14-composition.sh -- claim 0120 (Milestone 14, Card S3)
# class-B capstone gate: NOTEPAD.BIN's clipboard copy/paste (S1) and
# timer-driven cursor blink (S2) proven TOGETHER in the real app on VZ.
#
# The gate drives NOTEPAD end to end through the monitor's `dui key` seam:
#   exec NOTEPAD.BIN
#   dui key h  dui key e  dui key l  dui key l  dui key o   (type "hello")
#   dui key copy      (Ctrl+C -> sys_clipboard_set)
#   dui key paste     (Ctrl+V -> sys_clipboard_get)
# then, once the timer-driven cursor has blinked ("notepad: blink"):
#   dui close 2       (WIN_CLOSE -> NOTEPAD exits 43)
#   clipboard         (the shell's byte-exact read of the shared clipboard)
#   syscalls          (the syscall counts prove the S1/S2 slots were hit)
#
# WHY `dui key` and not the keyboard: a synthesized Ctrl-C/Ctrl-V chord
# CANNOT reach VZ's HID report — claim 0935's modifier wall (VZ drops the
# modifier flags on a synthesized keyDown; the guest sees the plain
# letter). `dui key` injects the SAME key event the keyboard path produces
# into the focused window's event queue, one layer above the HID->modifier
# translation VZ drops — the U5 `dui cycle` precedent (synthesizing the
# Alt+Tab focus signal) generalized to key chords. The interactive
# Ctrl-C/Ctrl-V/Ctrl-Q decode is host-tested in notepad.zig.
#
# Usage:
#   bash tools/verify-live-m14-composition.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m14-composition-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-m14-composition-report.txt"

echo "=== verify-live-m14-composition: claim 0120 — Milestone 14 S3 on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Phase 1: launch NOTEPAD (its window takes focus).
cat > artifacts/live-m14-composition-script.txt <<'EOF'
exec NOTEPAD.BIN
EOF

# Phase 2: type "hello", copy it (Ctrl+C), paste it back (Ctrl+V).
cat > artifacts/live-m14-composition-script2.txt <<'EOF'
dui key h
dui key e
dui key l
dui key l
dui key o
dui key copy
dui key paste
EOF

# Phase 3: after the timer-driven cursor blinked, close NOTEPAD's window
# (WIN_CLOSE -> exit 43) and read the shared clipboard + syscall counts.
cat > artifacts/live-m14-composition-script3.txt <<'EOF'
dui close 2
clipboard
syscalls
echo done-composition
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running the NOTEPAD composition (type/copy/paste/blink) on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --screen artifacts/gpu-screen \
    --script artifacts/live-m14-composition-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --screenshot-after "notepad: paste ok" \
    --script2 artifacts/live-m14-composition-script2.txt \
    --script2-after "notepad: ready" \
    --script3 artifacts/live-m14-composition-script3.txt \
    --script3-after "notepad: blink" \
    --script-expect "tasks user-exec exited status=43" \
    --timeout 90 > artifacts/live-m14-composition-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-m14-composition-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-m14-composition-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying NOTEPAD copy/paste + timer-cursor markers ---"

grep -q "notepad: copy ok" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: notepad: copy ok marker missing from serial log"
    exit 1
}
echo "COMP.COPY: OK"

grep -q "notepad: paste ok" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: notepad: paste ok marker missing from serial log"
    exit 1
}
echo "COMP.PASTE: OK"

grep -q "notepad: blink" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: notepad: blink marker missing from serial log (timer cursor)"
    exit 1
}
echo "COMP.BLINK: OK"

grep -q "notepad: win_close" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: notepad: win_close marker missing from serial log"
    exit 1
}
echo "COMP.CLOSE: OK"

echo "--- Phase 3: byte-exact clipboard + syscall seam ---"

grep -q "clipboard: len=5 'hello'" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: clipboard: len=5 'hello' missing from serial log (byte-exact round trip)"
    exit 1
}
echo "COMP.CLIPBOARD: OK"

grep -q "38 sys_clipboard_set calls=1" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: sys_clipboard_set calls=1 missing from syscalls report"
    exit 1
}
grep -q "39 sys_clipboard_get calls=1" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: sys_clipboard_get calls=1 missing from syscalls report"
    exit 1
}
echo "COMP.SYS_CLIPBOARD: OK"

grep -q "40 sys_timer_set calls=1" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: sys_timer_set calls=1 missing from syscalls report"
    exit 1
}
echo "COMP.SYS_TIMER: OK"

grep -q "tasks user-exec exited status=43" artifacts/live-m14-composition-serial.log || {
    echo "ERROR: NOTEPAD exit status 43 missing from serial log"
    exit 1
}
echo "COMP.LIFECYCLE: OK"

# Visual evidence: the marker-driven capture of the pasted window content.
if [ -f artifacts/gpu-screen-after ]; then
    echo "COMP.SCREENSHOT: OK (artifacts/gpu-screen-after)"
else
    echo "WARNING: marker-driven screenshot artifacts/gpu-screen-after missing (visual evidence)"
fi

cat > "$REPORT" <<EOF
=== Milestone 14 S3 Composition Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- NOTEPAD.BIN (the real app, real event loop, real timer) typed "hello",
  copied the line (sys_clipboard_set), pasted it back (sys_clipboard_get),
  and reported both markers — S1 clipboard copy/paste working live.
- The timer-driven cursor blinked ("notepad: blink" on the first TIMER
  event) — S2 app timers working live inside the app.
- The shell's \`clipboard\` read: "hello" byte-exact (len=5) after the copy.
- syscalls: sys_clipboard_set calls=1, sys_clipboard_get calls=1,
  sys_timer_set calls=1; NOTEPAD exited through the real lifecycle (43).
- The gate drives copy/paste through \`dui key\` (a synthesized key chord
  injected into the focused window's queue) because the synthesized Ctrl
  chord cannot reach VZ's HID report (claim 0935's modifier wall); the
  interactive Ctrl-C/Ctrl-V/Ctrl-Q decode is host-tested.

Serial Output Highlights:
$(grep -E 'notepad: (copy ok|paste ok|blink|win_close|ready|exiting)|dui key:|dui close:|clipboard: len=|sys_clipboard_(set|get) calls=|sys_timer_set calls=|user-exec exited' artifacts/live-m14-composition-serial.log || true)
EOF

echo "verify-live-m14-composition: PASS — NOTEPAD copy/paste + timer cursor verified together on VZ."
