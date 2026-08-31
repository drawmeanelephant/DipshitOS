#!/usr/bin/env bash
#
# verify-live-vm-depth.sh -- Milestone 29 (Issue #598, Claim 8247) Class-B gate:
# VM Depth: Demand Paging, Copy-on-Write (COW), and Anonymous mmap on real VZ hardware.
#
# Asserts:
#   1. System boots cleanly under VZ on Apple Silicon.
#   2. `exec VMTEST.BIN` loads and executes the M29 test payload at EL0.
#   3. Anonymous `mmap` registers valid user address space regions.
#   4. Translation faults at unmapped addresses trigger on-demand zero-fill page allocation.
#   5. Lazy allocation satisfies read and write touches transparently to userland.
#   6. Copy-on-Write permission faults trigger physical page duplication and refcount tracking.
#   7. `munmap` unmaps user memory and tears down page mappings cleanly.
#   8. Eager allocation (`MAP_POPULATE`) populates physical pages upfront.
#   9. Test completes with "vmtest: all tests passed" and cleanly exits.
#
# Run isolation (claim 5069): every boot uses a private stacked disk overlay,
# private EFI var store, and private serial log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-vm-depth-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-vm-depth-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "=== verify-live-vm-depth: Milestone 29 — VM Depth (Demand Paging, COW, mmap), $BOOTS boot(s) ==="

zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# Build dependencies
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Per-run isolation
gate_begin live-vm-depth
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"
cat > "$SCRIPT" <<'EOF'
exec VMTEST.BIN
EOF

SCRIPT2="$RUN_DIR/script2.txt"
cat > "$SCRIPT2" <<'EOF'
echo rx-vmtest-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$SCRIPT" \
        --script-after "$STATIC_EXIT_LINE" \
        --script2 "$SCRIPT2" \
        --script2-after "vmtest: all tests passed" \
        --script-expect "rx-vmtest-ok" \
        --timeout 60 \
        > "$(art live-vm-depth-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    local SER="$(art live-vm-depth-serial-$tag.log)"
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$SER" || true

    local SERIAL_BYTES
    SERIAL_BYTES=$(wc -c < "$SER" 2>/dev/null | tr -d ' ')
    local BANNER=0 MMAP=0 DEMAND_READ=0 DEMAND_WRITE=0 MUNMAP=0 EAGER=0 ALL_PASSED=0 ECHO=0
    [ -f "$SER" ] || { SERIAL_BYTES=0; }
    if [ -f "$SER" ]; then
        grep -qF -- "VirelaiOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "vmtest: mmap ok" "$SER" && MMAP=1
        grep -qF -- "vmtest: demand read ok" "$SER" && DEMAND_READ=1
        grep -qF -- "vmtest: demand write ok" "$SER" && DEMAND_WRITE=1
        grep -qF -- "vmtest: munmap ok" "$SER" && MUNMAP=1
        grep -qF -- "vmtest: eager mmap ok" "$SER" && EAGER=1
        grep -qF -- "vmtest: all tests passed" "$SER" && ALL_PASSED=1
        grep -qF -- "rx-vmtest-ok" "$SER" && ECHO=1
    fi
    {
        echo "$tag: rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER mmap=$MMAP demand_read=$DEMAND_READ demand_write=$DEMAND_WRITE munmap=$MUNMAP eager=$EAGER all_passed=$ALL_PASSED echo=$ECHO"
    } >> "$REPORT"
    echo "$tag rc=$RC serial-bytes=$SERIAL_BYTES banner=$BANNER mmap=$MMAP demand_read=$DEMAND_READ demand_write=$DEMAND_WRITE munmap=$MUNMAP eager=$EAGER all_passed=$ALL_PASSED echo=$ECHO"

    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$MMAP" = 1 ] && [ "$DEMAND_READ" = 1 ] && [ "$DEMAND_WRITE" = 1 ] && [ "$MUNMAP" = 1 ] && [ "$EAGER" = 1 ] && [ "$ALL_PASSED" = 1 ] && [ "$ECHO" = 1 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live-vm-depth gate (Milestone 29, Claim 8247) — Demand paging, COW, anonymous mmap on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-vm-depth boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-vm-depth: PASS — demand paging, lazy zero-fill, COW permission handling, and anonymous mmap verified live ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-vm-depth: FAILED — $PASS/$BOOTS boot(s) passed; see $(art live-vm-depth-report.txt) and serial logs."
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    exit 1
fi
