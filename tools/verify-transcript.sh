#!/usr/bin/env bash
# M1.5 march step 19 gate: the automated `dipshit>` transcript test.
#
# Proves the prompt + command loop without manual typing:
#   1. `zig test kernel/src/shell.zig` must pass (the mock-fed end-to-end
#      test asserts the exact transcript in-test).
#   2. That e2e test writes the captured mock output to
#      artifacts/m15-mock-transcript.txt; this gate diffs it byte-for-byte
#      against the canonical, checked-in fixture tests/transcript-console.txt.
#
# The live half of march row 19 (asserting the same bytes in vm-serial.log
# on a real VZ run) stays gated on claim 0002: until the VZ serial gate
# proves a device, the kernel adapter's readByte is an [inferred] no-RX stub
# and keystrokes cannot reach a live VM. The mock transcript exercises the
# same prompt/read/tokenize/exec path the kernel will drive.
#
# Run from the repo root (`zig build test-console`, `just test-console`, CI).
# Note: the e2e test writes artifacts/m15-mock-transcript.txt, so the
# artifacts/ directory must exist on checkout — keep artifacts/.gitkeep
# tracked (it is); a future .gitignore cleanup would break this gate.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== transcript gate 1: shell module tests (zig test kernel/src/shell.zig) ==="
zig test kernel/src/shell.zig

echo "=== transcript gate 2: emitted transcript vs canonical fixture ==="
[ -f artifacts/m15-mock-transcript.txt ] || { echo "FAIL: artifacts/m15-mock-transcript.txt missing (did the e2e test run?)"; exit 1; }
[ -f tests/transcript-console.txt ] || { echo "FAIL: tests/transcript-console.txt missing"; exit 1; }
diff -u tests/transcript-console.txt artifacts/m15-mock-transcript.txt

echo "verify-transcript: PASS — mock transcript is byte-identical to the canonical fixture"
