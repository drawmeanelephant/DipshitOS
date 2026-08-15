#!/usr/bin/env bash
#
# verify-glyph-raster.sh -- class A: the font8x8 LSB-first glyph raster
# convention, as a NAMED gate (claim 9358, issue 125 hardening).
#
# The issue-125 lesson: a golden that derives its expectation from the code
# under test cannot catch a regression (the old decoder sampled into bits
# 7->0 and matched the raw LSB-first byte, so it was self-consistent with
# the mirrored kernel). The full-table goldens in text.zig /
# driving_award.zig read the RAW table bits inline and the table
# fingerprint in font8x8.zig pins the source data — but they only catch a
# flip if they are actually RUN and if they actually FAIL when the
# convention reverses. This gate makes both facts mechanical:
#
#   1. Run the three glyph-bearing module tests explicitly (the broad
#      verify-unit-tests.sh aggregate also runs them, but a glyph-raster
#      regression should have a NAMED gate so the failure is attributable).
#   2. Run the offline in-cell mirror self-test (decode-screen-glyphs.py
#      --self-test, the class-A mirror tripwire).
#   3. MUTATION CHECK (delegated to the generalized
#      tools/verify-mutations.sh, claim 3485): the glyph row_pixel
#      reversal is one manifest entry among the kernel's bit-order seams
#      (FAT read_le endianness, virtio chain-walk NEXT bit). Each mutation
#      is applied, the module tests MUST fail, and the file is restored.
#      A golden that cannot detect the bug it exists for fails the gate.
#
# Class A — deterministic, no Apple silicon, no VZ VM. Wired into
# `just verify-portable` and GitHub CI (the class-A set).
#
# Usage:
#   bash tools/verify-glyph-raster.sh
#
# Evidence: the script's own stdout (gate log), plus the module test
# outputs and the self-test output it forwards.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODULES=(font8x8 text driving_award)

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== verify-glyph-raster: the font8x8 LSB-first convention, as a named class-A gate ==="

# --- 1. The glyph-bearing module tests (the raster goldens) -------------
echo
echo "[1/3] raster-golden module tests (font8x8 + text + driving_award)"
for m in "${MODULES[@]}"; do
    echo "-- zig test kernel/src/$m.zig"
    zig test "kernel/src/$m.zig"
done
echo "module goldens: PASS"

# --- 2. The offline in-cell mirror self-test ----------------------------
echo
echo "[2/3] offline in-cell mirror self-test (decode-screen-glyphs.py --self-test)"
python3 tools/decode-screen-glyphs.py --self-test
echo "offline self-test: PASS"# --- 3. Mutation check: delegated to the generalized bit-order gate ---
echo
 echo "[3/3] mutation check (delegated: tools/verify-mutations.sh — row_pixel reversal + FAT endianness + virtio NEXT-bit)"
bash tools/verify-mutations.sh
echo "mutation check: PASS (every bit-order mutation failed its goldens)"

echo
echo "=== verify-glyph-raster: PASS (goldens green, self-test green, mutation detected) ==="
