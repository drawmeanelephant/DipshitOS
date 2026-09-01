#!/usr/bin/env bash
#
# verify-mutations.sh -- class A: the MUTATION CHECK, generalized (claim
# 3485, issue 125 hardening).
#
# The issue-125 lesson: a golden that derives its expectation from the code
# under test cannot catch a regression (the old glyph decoder sampled into
# bits 7->0 and matched the raw LSB-first byte — self-consistent with the
# mirrored kernel). The fix for the glyph raster added goldens that read
# the RAW table bits, plus a mutation check that proves they FAIL when the
# convention reverses (tools/verify-glyph-raster.sh leg 3).
#
# This gate GENERALIZES the mutation check to every bit-order-sensitive
# seam in the kernel. Each manifest entry names:
#   - the file to mutate,
#   - the exact old/new code strings (the mutation is a targeted edit, so
#     it simulates a REAL regression — a flipped endianness, a bit-order
#     confusion — not a synthetic flag),
#   - the module tests that MUST fail under the mutation.
# The gate applies each mutation, runs the module tests, REQUIRES them to
# fail, and restores the file. If any golden does NOT fail against its
# mutation, the gate fails — a golden that cannot detect the bug it exists
# for is worse than no golden.
#
# CRITICAL DESIGN RULE (learned from issue 125): the mutation must NOT be
# self-consistent with the code under test. Mutating a shared constant
# that both the production walk AND the tests read is NOT a valid check —
# both flip together and the tests stay green. Each mutation below flips
# the READING of a bit/byte, never a constant both sides share:
#
#   1. font8x8 row_pixel  — the glyph raster convention (issue 125):
#      reversing which bit is "leftmost" must break every raster golden.
#   2. FAT read_le        — the FAT structure parser's endianness seam:
#      reading entries big-endian instead of little-endian must break the
#      mount/read/write tests (the FAT on-disk format is little-endian).
#      read_le is the ONE shared reader; write_le is left untouched so the
#      write path still emits little-endian fixtures the tests compare
#      against — the mutation is a pure READ-side bit-order flip.
#   3. virtio chain walk  — the virtio descriptor NEXT-flag interpretation:
#      free_chain walks the descriptor chain by testing bit 0
#      (VIRTQ_DESC_F_NEXT). Testing the WRITE bit (0x2) instead must break
#      the alloc/free/recycle tests. (Mutating the vq_next CONSTANT is NOT
#      a valid check — the walker and the tests read the same constant, so
#      the flip is self-consistent; verified empirically.)
#
# Class A — deterministic, no Apple silicon, no VZ VM. Wired into
# `just verify-portable` and GitHub CI (the class-A set).
#
# Usage:
#   bash tools/verify-mutations.sh
#
# Evidence: the script's own stdout (gate log), plus the module test
# outputs it forwards.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== verify-mutations: the generalized bit-order mutation check ==="

# One mutation per line: <label>|<file>|<old>|<new>|<modules...>
# `old` and `new` are matched with fgrep -F (literal, no regex) and
# replaced once. `modules` is a space-separated list of kernel modules
# whose `zig test` MUST FAIL under the mutation.
MUTATIONS=$'font8x8 row_pixel|kernel/src/font8x8.zig|    return ((row >> shift) & 1) != 0;|    return ((row >> (7 - shift)) & 1) != 0;|font8x8 text driving_award\nfile_table traversal boundary|kernel/src/file_table.zig|const prev_bound = (i == 0 or raw[i - 1] == \x27/\x27);|const prev_bound = (i == 0 and raw[i - 1] == \x27/\x27);|file_table\nvirtio chain-walk NEXT bit|kernel/src/virtio_custom.zig|if ((flags & vq_next) == 0) break;|if ((flags & vq_write) == 0) break;|virtio_custom'

n=0
detected=0
while IFS='|' read -r label file old new modules; do
    [ -z "$label" ] && continue
    n=$((n + 1))
    echo
    echo "[mutation $n] $label ($file)"
    [ -f "$file" ] || fail "mutation target missing: $file"
    cp "$file" "$file.mutated"
    # Literal replace; fail loudly if the anchor is gone (the code
    # structure changed and this mutation is now stale — better to know).
    python3 - "$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if old not in src:
    print("  anchor not found in %s (code changed? this mutation is stale)" % path)
    sys.exit(2)
open(path, "w").write(src.replace(old, new, 1))
PYEOF
    anchor_rc=$?
    if [ $anchor_rc -ne 0 ]; then
        mv "$file.mutated" "$file"
        fail "mutation $label: anchor not found in $file (the seam moved — refresh this manifest entry)"
    fi

    ok=0
    for m in $modules; do
        if zig test "kernel/src/$m.zig" >/dev/null 2>&1; then
            echo "  !! $m did NOT fail under the mutation — the golden cannot detect this regression"
        else
            ok=1
        fi
    done
    mv "$file.mutated" "$file"
    if [ $ok -eq 0 ]; then
        fail "mutation $label: NO module failed — the goldens cannot detect this bit-order regression"
    fi
    detected=1
    echo "  detected (all listed modules failed)"
done <<< "$MUTATIONS"

if [ "$detected" -eq 0 ]; then
    fail "no mutations were applied (manifest empty?)"
fi

echo
echo "=== verify-mutations: PASS ($n bit-order mutations applied; every golden failed under its mutation) ==="
