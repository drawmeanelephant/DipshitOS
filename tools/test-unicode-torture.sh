#!/usr/bin/env bash
# M20-U14: the Unicode torture gate.
#
# Renders tools' torture document (embedded at
# kernel/src/unicode-torture.txt) through the real text layer and pins
# the rendered pixels against an in-test FNV golden — any rendering or
# font-table change shifts the fingerprint and fails here.
#
# Class A (host-only, deterministic). Run from the repo root.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f kernel/src/unicode-torture.txt ] || { echo "FAIL: kernel/src/unicode-torture.txt missing"; exit 1; }

echo "=== unicode-torture: rendering the torture document through text.zig ==="
zig test kernel/src/text.zig

echo "verify-unicode-torture: PASS — torture document matches its pixel golden"
