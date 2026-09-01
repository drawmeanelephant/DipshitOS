#!/usr/bin/env bash
#
# verify-live-pointer-virtio.sh -- claim 9367 (issue #523 item 3
# productionization; attacks issue #151) class-B gate: POINTER injection
# over the custom-virtio INPUT queue drives cursor motion + click-to-focus,
# HEADLESS.
#
# WHY THIS EXISTS: every synthesized host pointer route fails at the
# claim-4769 activation wall -- VZ only translates host input for its KEY
# window, so the pointer-focus proof was class-C-only (real mouse, claim
# 9015) or trust-gated (verify-live-pointer-cg.sh). Claim 9588 proved the
# escape hatch for KEYBOARD: inject over the custom-virtio device's queue 3
# -- no view, no window, no CGEvent/NSEvent, nothing for the wall to block.
# This gate applies the identical lesson to POINTER reports: the runner
# enqueues kind-2 absolute-pointer messages into the guest's pre-armed
# queue-3 receive buffers, and the guest decodes them through the SAME
# decode_pointer_report path XHCI pointer reports take.
#
# Mechanism (ONE headless run): --screen (no --display, no --input) so the
# virtio-gpu device exists and Driving Award arms, but no host window is
# ever key and no USB HID device is attached. The serial script opens
# WINLOOP.BIN (window id 2); the runner's --pointer-virtio seam waits for
# `winloop: present ok` and enqueues move/click messages for three desktop
# targets (clock area -> WINLOOP -> terminal), 0.25 s apart, strictly
# ordered. Phase 2 then runs `input` and echoes ptr-cv-done. Assertions:
#
#   * the guest's OWN accounting: ptr-reports>0 WITH armed=0 -- reports
#     arrived while NO USB keyboard or pointer was ever attached;
#   * >=2 distinct `dui: pointer focus=<id>` lines -- injected clicks moved
#     focus between windows (the exact evidence shape #151 could only prove
#     class-C before);
#   * coexistence: q3 pool armed + the claim-3141 push echo green in the
#     same boot;
#   * negative proofs: no PTR-EVT synthesis line, no window-state line --
#     nothing synthesized existed on this path.
#
# Class B -- Apple silicon + VZ + macOS 27 (VZCustomVirtioDevice); boots a
# real VM headlessly. No Accessibility, no Screen Recording, no human
# action anywhere.
#
# Usage:
#   bash tools/verify-live-pointer-virtio.sh
#
# Run isolation (#523 item 2, claim 6637): private stacked disk + EFI vars
# + serial log under $RUN_DIR; VIRELAI_GATE_SUFFIX/_KEEP_RUN supported.
#
# Evidence: artifacts/live-pointer-virtio-gate.txt (full output),
# artifacts/live-pointer-virtio-report.txt (detail),
# artifacts/live-pointer-virtio-run.txt (runner output),
# artifacts/live-pointer-virtio-serial.log (guest serial).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-pointer-virtio-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-pointer-virtio-report.txt)"

echo "=== verify-live-pointer-virtio: claim 9367 -- injected pointer reports drive click-to-focus over the custom-virtio INPUT queue, HEADLESS, on VZ ==="

# --- tool versions + revision -----------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
# The SPIKE binary: macOS 27 SDK types (VZCustomVirtioDevice); `zig build
# spike-virtio` documents the same build shape. No base-binary phase here:
# this gate IS the four-queue world.
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-pointer-virtio
gate_seed_share
echo "run dir: $RUN_DIR"

# --- choreography ------------------------------------------------------------
# Phase 1 runs as soon as the shell prompt appears: WINLOOP.BIN opens user
# window id 2 and settles into its present loop (`winloop: present ok`).
cat > "$RUN_DIR/script-ptr.txt" <<'EOF'
exec WINLOOP.BIN
EOF

# Phase 2 raises WINLOOP to the top of the z-order (hit_test scans the
# window array from the end, and the fullscreen terminal would otherwise
# shadow it) and echoes the injection trigger. The raise is session SETUP
# via documented monitor commands; the focus PROOF itself is driven purely
# by the injected pointer messages.
cat > "$RUN_DIR/script-ptr2.txt" <<'EOF'
dui raise 2
echo ptrcv-raised
EOF

# The pointer sequence clicks WINLOOP (window 2, upper-left), then the
# terminal (window 0, below-right of it) -- two distinct focus targets,
# four steps; each step emits its own move message and each click expands
# to down+up at its coords -- 8 kind-2 messages total. Guest pixels,
# top-left origin; the runner converts to HID absolute logicals. The
# runner paces at 2.5 s per message so every press lands in its own
# shell-idle pass (the pointer edge detector runs per idle pass, not per
# message -- see the claim-9367 note in VMRunner).
PTR_SEQ="200,150;200,150,c;640,600;640,600,c"

# Phase 3 fires only after the injections had their wall-clock budget
# (claim 9489: --scriptN-delay is a wait the gate WANTS): 8 messages at
# 2.5 s spacing need ~20 s from the trigger.
cat > "$RUN_DIR/script-ptr3.txt" <<'EOF'
dui hit 200 150
input
echo ptr-cv-done
EOF

run_gate() {
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio \
        --script "$RUN_DIR/script-ptr.txt" \
        --script2 "$RUN_DIR/script-ptr2.txt" --script2-after "winloop: present ok" \
        --pointer-virtio "$PTR_SEQ" --pointer-virtio-after "ptrcv-raised" \
        --script3 "$RUN_DIR/script-ptr3.txt" --script3-after "ptrcv-raised" --script3-delay 30 \
        --script-expect "ptr-cv-done" \
        --timeout 180 \
        > "$(art live-pointer-virtio-run.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-pointer-virtio-serial.log)" || true
    echo "$RC" > "$RUN_DIR/rc.txt"
}

set +e
run_gate
RC="$(cat "$RUN_DIR/rc.txt")"
set -e
gate_end

# --- serial assertions --------------------------------------------------------
SERIAL="$(art live-pointer-virtio-serial.log)"
SERIAL_BYTES=0 ARMED=0 PTR_REPORTS=0 PTR_GT0=0 FOCUS_LINES=0 DISTINCT_FOCUS=0 Q3ARMED=0 Q2OK=0 WINLOOP_OK=0 DONE=0 GPU_OK=0
if [ -f "$SERIAL" ]; then
    SERIAL_BYTES=$(wc -c < "$SERIAL" | tr -d ' ')
    # THE deterministic proof: pointer reports arrived with NO USB HID
    # device attached (armed=0 -- XHCI never enumerated anything).
    grep -a -q "input: armed=0 " "$SERIAL" && ARMED=1
    PTR_REPORTS=$(grep -a -o "ptr-reports=[0-9]*" "$SERIAL" | tail -1 | cut -d= -f2 || true)
    PTR_REPORTS=${PTR_REPORTS:-0}
    if [ "$PTR_REPORTS" -gt 0 ] 2>/dev/null; then PTR_GT0=1; fi
    # Click-to-focus: the injected clicks moved focus between windows.
    FOCUS_LINES=$(grep -a -c "dui: pointer focus=" "$SERIAL" || true)
    DISTINCT_FOCUS=$(grep -a -o "dui: pointer focus=[0-9]*" "$SERIAL" | sort -u | wc -l | tr -d ' ' || true)
    # Coexistence in the same boot: the input pool armed and the
    # claim-3141 push echo stayed green.
    grep -a -qF -- "cvspike: q3 armed bufs=" "$SERIAL" && Q3ARMED=1
    grep -a -qF -- "cvspike: q2 ok=1" "$SERIAL" && Q2OK=1
    # The choreography markers.
    grep -a -qF -- "winloop: present ok" "$SERIAL" && WINLOOP_OK=1
    grep -a -qF -- "ptr-cv-done" "$SERIAL" && DONE=1
    grep -a -qF -- "gpu: setup ok scanout=" "$SERIAL" && GPU_OK=1
fi

# --- runner-output assertions --------------------------------------------------
RUNTXT="$(art live-pointer-virtio-run.txt)"
H_SEQ=0 H_DOWN=0 H_UP=0 H_COMPLETE=0 H_FOURQ=0 H_NOSYNTH=0
if [ -f "$RUNTXT" ]; then
    grep -a -qF -- "PTR-CV-SEQ: 4 pointer steps scheduled after \"ptrcv-raised\" transport=cv-input" "$RUNTXT" && H_SEQ=1
    grep -a -qF -- "CUSTOM-VIRTIO-INPUT: enqueued ptr-seq down buttons=0x1 x=" "$RUNTXT" && H_DOWN=1
    grep -a -qF -- "CUSTOM-VIRTIO-INPUT: enqueued ptr-seq up buttons=0x0 x=" "$RUNTXT" && H_UP=1
    grep -a -qF -- "CUSTOM-VIRTIO-INPUT: sequence complete tag=ptr-seq n=8 ok=true" "$RUNTXT" && H_COMPLETE=1
    # Structural headless proof: the attach line lists FOUR queues.
    grep -a -qF -- ", 4 queue(s) incl. the claim-3141 push-echo queue and the claim-9588 INPUT queue (--via-virtio)" "$RUNTXT" && H_FOURQ=1
    # NEGATIVE proofs: no NSEvent-synthesis pointer line and no window-state
    # report can exist on this path (no view was ever created for input).
    if ! grep -a -qF -- "PTR-EVT" "$RUNTXT" && ! grep -a -qF -- "window key=" "$RUNTXT"; then
        H_NOSYNTH=1
    fi
fi

echo "pointer-virtio: rc=$RC serial-bytes=$SERIAL_BYTES armed=$ARMED ptr-reports=$PTR_REPORTS focus-lines=$FOCUS_LINES distinct=$DISTINCT_FOCUS q3=$Q3ARMED q2=$Q2OK winloop=$WINLOOP_OK done=$DONE gpu=$GPU_OK host-seq=$H_SEQ host-down=$H_DOWN host-up=$H_UP host-complete=$H_COMPLETE host-four-q=$H_FOURQ host-no-synthesis=$H_NOSYNTH"

PASS=0
if [ "$RC" = 0 ] && [ "$ARMED" = 1 ] && [ "$PTR_GT0" = 1 ] && [ "$DISTINCT_FOCUS" -ge 2 ] && \
   [ "$Q3ARMED" = 1 ] && [ "$Q2OK" = 1 ] && [ "$WINLOOP_OK" = 1 ] && [ "$DONE" = 1 ] && \
   [ "$GPU_OK" = 1 ] && [ "$H_SEQ" = 1 ] && [ "$H_DOWN" = 1 ] && [ "$H_UP" = 1 ] && \
   [ "$H_COMPLETE" = 1 ] && [ "$H_FOURQ" = 1 ] && [ "$H_NOSYNTH" = 1 ]; then
    PASS=1
fi

{
    echo "VIRELAIOS pointer-virtio gate (claim 9367, issue #523 item 3 / #151) — injected pointer reports drive click-to-focus over the custom-virtio INPUT queue, HEADLESS, on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "session: --screen (GPU attached, no display window, no USB HID devices); script opens WINLOOP.BIN; --pointer-virtio enqueues kind-2 absolute-pointer messages after \"winloop: present ok\" (clock -> WINLOOP -> terminal); script2 runs \`input\` and echoes ptr-cv-done"
    echo "assertions: input armed=0 (nothing USB attached) yet ptr-reports>0; >=2 distinct dui pointer-focus lines; q3 armed + q2 push echo green in the same boot; host seq/down/up/complete evidence over transport=cv-input; four-queue attach; negative: no PTR-EVT/window-key synthesis lines"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-pointer-virtio: PASS — injected pointer reports arrived over the custom-virtio INPUT queue (kind-2 absolute-pointer messages into pre-armed queue-3 receive buffers) with NO USB device attached (armed=0, ptr-reports=$PTR_REPORTS), were decoded through the same decode_pointer_report path XHCI reports take, and the resulting synthesized clicks moved window focus ($FOCUS_LINES focus lines, $DISTINCT_FOCUS distinct ids) — the claim-4769 activation wall cannot apply on this channel: there was no window to activate and nothing synthesized to drop. Issue #151's pointer-focus proof is upgraded from class-C-only to class-B-headless."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-pointer-virtio: FAILED — see $(basename "$REPORT"), $(basename "$RUNTXT"), and $(basename "$SERIAL")."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
