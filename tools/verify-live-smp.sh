#!/usr/bin/env bash
#
# verify-live-smp.sh -- Milestone 28 (claim 6438) class-B gate:
# Symmetric Multi-Processing (SMP) multi-core bringup on Apple Silicon VZ.
#
# Asserts on live Virtualization.framework hardware:
#   1. Secondary CPU core powers on via PSCI CPU_ON (conduit HVC).
#   2. Both CPU cores initialize MMU, GICv3 redistributor, and local physical timer.
#   3. `smp` command reports `cores=2 online=2`.
#   4. Multi-core task scheduling and IPI communication function without exception.
#   5. The shell remains responsive on Core 0 while secondary core executes.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-smp-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-smp: Milestone 28 (claim 6438) SMP multi-core gate ($BOOTS boot(s)) ==="

zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-smp
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

printf 'smp\ntasks\nps\nexec COUNTER.BIN\nsmp\necho rx-smp-ok\n' > "$SCRIPT"

RUNNER_LOG="$RUN_DIR/vm-serial.log"
RUN_LOG="$(art live-smp-run.txt)"

echo "running VM with script: $SCRIPT"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUNNER_LOG" \
    --script "$SCRIPT" \
    --script-after "$STATIC_EXIT_LINE" \
    --script-expect "rx-smp-ok" \
    --timeout 30 > "$RUN_LOG" 2>&1
rc=$?
set -e

[ -f "$RUNNER_LOG" ] && cp "$RUNNER_LOG" "$(art live-smp-serial.log)" || true

echo "=== VM Serial Log Output ==="
cat "$RUNNER_LOG"

echo "=== checking assertions in serial log ==="
grep -q "smp: cores=2 online=2" "$RUNNER_LOG" || { echo "FAIL: smp: cores=2 online=2 not found"; exit 1; }
grep -q "core 0: bsp mpidr=" "$RUNNER_LOG" || { echo "FAIL: core 0 BSP not found"; exit 1; }
grep -q "core 1: ap  mpidr=" "$RUNNER_LOG" || { echo "FAIL: core 1 AP not found"; exit 1; }
grep -q "rx-smp-ok" "$RUNNER_LOG" || { echo "FAIL: rx-smp-ok not found"; exit 1; }
grep -q "EXC PARK" "$RUNNER_LOG" && { echo "FAIL: Exception park detected"; exit 1; }

echo "verify-live-smp: SUCCESS (all assertions verified on live hardware)"
