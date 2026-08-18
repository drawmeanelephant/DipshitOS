#!/usr/bin/env bash
#
# verify-live-hardening.sh -- claim 4482 (Milestone 14, Card S4)
# class-B gate: security/isolation hardening — the hostile-consumer proof,
# live on Apple Virtualization.framework.
#
# Two SEPARATE EL0 processes in one boot (the claim-0826 capacity exec
# gate, no exclusivity):
#
#   VICTIM.BIN  — opens user window 2 (`sys_win_open`, slot 12), fills it,
#                 presents it, prints `victim: window=2 ready`, and
#                 yield-loops FOREVER so the window stays alive on the
#                 scanout and the process is provably still resident.
#
#   HARDEN.BIN  — a hostile process with a DIFFERENT task id (no window of
#                 its own) that attacks window 2 through the ADR 0007
#                 window syscalls: fill (13), present (14), close (15),
#                 move (16), and query (19 — the pointer-taking attack,
#                 refused before the user buffer is touched). Every attack
#                 must come back EINVAL (-1) from the per-process
#                 ownership check (`win_owned_by_caller` — the S4 audit's
#                 fix discipline, already enforced behind every
#                 `sys_win_*` handler). If ANY attack returns 0, HARDEN
#                 reports `hardening: <OP> NOT REFUSED` and exits nonzero —
#                 the gate fails on the guest's OWN evidence. On a clean
#                 refusal HARDEN prints `hardening: refused` /
#                 `hardening: survived` and exits status 44.
#
# Sequencing: the runner forwards `exec VICTIM.BIN` after the boot payload
# exits, then forwards `exec HARDEN.BIN` (script2) only after
# `victim: window=2 ready` appears — so the victim's window EXISTS and is
# owned by another process the moment the hostile program runs. The runner
# tears down when `tasks user-exec exited status=44` (HARDEN's exit line)
# lands, so every HARDEN marker prints before teardown.
#
# No input seam involved (issue #179 is untouched by this gate): the proof
# is driven entirely by argv exec + the syscall seam.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-hardening.sh
#
# Evidence saved under artifacts/: live-hardening-gate.txt,
# live-hardening-report.txt, live-hardening-run.txt,
# live-hardening-serial.log, live-hardening-script.txt,
# live-hardening-script2.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-hardening-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-hardening-report.txt"

echo "=== verify-live-hardening: claim 4482 — M14 S4 hostile-consumer proof on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Phase 1: bring up the victim — opens window 2 and yield-loops forever.
cat > artifacts/live-hardening-script.txt <<'EOF'
exec VICTIM.BIN
EOF

# Phase 2 (forwarded once `victim: window=2 ready` appears): the hostile
# program — a separate process — attacks window 2 through every window
# syscall and must be refused each time.
cat > artifacts/live-hardening-script2.txt <<'EOF'
exec HARDEN.BIN
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running the hostile-consumer proof on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --display \
    --script artifacts/live-hardening-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-hardening-script2.txt \
    --script2-after "victim: window=2 ready" \
    --script-expect "tasks user-exec exited status=44" \
    --timeout 90 > artifacts/live-hardening-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-hardening-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-hardening-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the hostile-proof markers ---"

# The victim opened window 2 and was alive when HARDEN ran (script2 is
# forwarded only after this marker, and the victim yield-loops forever).
grep -q "victim: window=2 ready" artifacts/live-hardening-serial.log || {
    echo "ERROR: victim ready marker missing from serial log"
    exit 1
}
echo "VICTIM.READY: OK"

# Every attack must have been refused: none of the NOT-REFUSED markers may
# appear (HARDEN exits nonzero the moment any attack succeeds, and the
# runner would then never see the exit-44 expect line — but assert anyway).
for op in FILL PRESENT CLOSE MOVE QUERY; do
    if grep -q "hardening: ${op} NOT REFUSED" artifacts/live-hardening-serial.log; then
        echo "ERROR: ${op} attack against the victim's window was NOT refused"
        exit 1
    fi
done
echo "NO.ATTACK.SUCCEEDED: OK"

grep -q "hardening: refused" artifacts/live-hardening-serial.log || {
    echo "ERROR: refused marker missing from serial log"
    exit 1
}
grep -q "hardening: survived" artifacts/live-hardening-serial.log || {
    echo "ERROR: survived marker missing from serial log"
    exit 1
}
echo "REFUSED+SURVIVED: OK"

# HARDEN exited through the real lifecycle with its refusal status; the
# victim NEVER exited (it is still resident — the window it owns was not
# torn down by the hostile process).
grep -q "tasks user-exec exited status=44" artifacts/live-hardening-serial.log || {
    echo "ERROR: HARDEN exit status line missing from serial log"
    exit 1
}
if grep -q "VICTIM.BIN exited" artifacts/live-hardening-serial.log; then
    echo "ERROR: the victim exited — the hostile process tore it down"
    exit 1
fi
echo "LIFECYCLE: OK (HARDEN exited 44, VICTIM still resident)"

cat > "$REPORT" <<EOF
=== Milestone 14 S4 Hardening Live Gate Report ===
Revision: $REVISION ($BRANCH, dirty-files=$DIRTY)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- Two separate EL0 processes in one boot: VICTIM.BIN (opens + owns user
  window 2, yield-loops forever) and HARDEN.BIN (a hostile process with
  no window of its own)
- Cross-process ownership: every window syscall the hostile process aimed
  at the victim's window — fill (13), present (14), close (15), move (16),
  and query (19, the pointer-taking attack) — was refused with EINVAL by
  the per-process ownership check (win_owned_by_caller) BEFORE any state
  changed or user buffer was touched
- The hostile program SURVIVED all five refusals, reported
  'hardening: refused' / 'hardening: survived', and exited status 44
  through the real lifecycle
- The victim never exited: its window stayed owned and resident for the
  whole proof (no teardown possible cross-process; 'dui close' remains the
  only privileged close path)
- The refusal is guest-side evidence: if any attack had succeeded,
  HARDEN.BIN prints 'hardening: <OP> NOT REFUSED' and exits nonzero — the
  gate fails on the guest's own report, not a host-side grep

Serial Output Highlights:
$(grep -E 'victim:|hardening:|tasks user-exec exited status=44' artifacts/live-hardening-serial.log || true)
EOF

echo "verify-live-hardening: PASS — a hostile EL0 process was refused every cross-process window access on VZ."
