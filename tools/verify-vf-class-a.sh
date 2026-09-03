#!/usr/bin/env bash
#
# verify-vf-class-a.sh -- M34 HF1–HF4 (issues #735/#736/#737/#738) class-A
# gate: the host file channel wire format is pinned BYTE-FOR-BYTE on both
# sides, and every transport fact that needs no VM is asserted here.
# HF4 (issue #738) adds no wire ops — the exec host source rides READ/STAT
# (chunked via virtio_file.read_into) and the /host file-table partition
# rides LIST/READ/STAT, so this gate's parity pins still cover it.
#
#   G1-G12  kernel/src/virtio_file.zig host tests (generator parity,
#           reply_len clamp math, probe framing, hostile envelopes, entry
#           rows + streaming cksum, request encode bounds, HF3 mutation
#           wire: op/status constants + 8-handle parity, open flags +
#           reply handle, write/truncate payloads, rename NUL framing,
#           chunk plan)
#   S1-S10  host/vm-runner Tests/VMRunnerTests (fixture parity + path
#           defense + HF3 wire parity + the 8-slot FileHandleTable cursor
#           semantics) via `swift test`
#   fixture sha256 pins: the checked-in tests/vf-*.bin must not drift, and
#          python must regenerate vf-pattern-32k.bin byte-for-byte
#   zig fmt/build/image, BSS budget (11.0 MiB), coordination
#
# Class A -- pure host-side, no VM, runs in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/m34-hf1-class-a.txt"
mkdir -p artifacts
exec > >(tee "$GATE_LOG") 2>&1

echo "=== verify-vf-class-a: M34 HF1–HF4 (issues #735/#736/#737/#738) — host file channel wire parity (class A) ==="
zig version
swift --version 2>&1 | head -1
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

status=0
step() { echo; echo "── $* ──"; }

step "zig fmt --check"
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig

step "zig build"
zig build

step "zig build image"
zig build image

step "virtio_file host tests (G1–G12)"
zig test kernel/src/virtio_file.zig

step "verify-unit-tests.sh (all monitor modules incl. virtio_file)"
bash tools/verify-unit-tests.sh

step "swift test (VFWire S1–S10)"
swift test --package-path host/vm-runner

step "fixture sha256 pins + python generator cross-check"
python3 - <<'EOF'
import hashlib, sys

def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)

pins = {
    "vf-pattern-32k.bin": "8b16fec9d2a8c48be47789a462c2d4b3d9be75ec91310607ec5fb5e180982ed5",
    "vf-req-read.bin": "605f3306e9b608dcf763e7b8498438cbb3b4b160620160eed35c984627a14724",
    "vf-reply-read.bin": "c018a33ef9fe2bb21707201011270883aa7dc3da2b5ab368687255da5197e3ce",
    "vf-reply-list.bin": "710a1372b7a64e14c53105774e37ccfb5cb9e6a93e889a4c76b6039acd83e909",
}
ok = True
for name, pin in pins.items():
    data = open("tests/" + name, "rb").read()
    got = hashlib.sha256(data).hexdigest()
    match = got == pin
    ok = ok and match
    print(f"{name}: {len(data)} B sha256={got} {'OK' if match else 'PIN-MISMATCH'}")

# python must regenerate the 32 KiB pattern exactly.
regenerated = bytes(pattern(i) for i in range(32768))
checked = open("tests/vf-pattern-32k.bin", "rb").read()
if regenerated != checked:
    print("vf-pattern-32k.bin: python generator MISMATCH")
    ok = False
else:
    print("vf-pattern-32k.bin: python generator reproduces the fixture byte-for-byte")

# RFC-1071 of the pattern (all three sides must agree — guest Zig, Swift,
# python): the XOR-symmetric pattern folds to 0x0000.
def cksum(data):
    s = 0
    i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data):
        s += data[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
print(f"pattern cksum1071 = 0x{cksum(regenerated):04x}")
sys.exit(0 if ok else 1)
EOF

step "verify-bss-budget.sh"
bash tools/verify-bss-budget.sh

step "verify-issue-coordination.sh"
bash tools/status/verify-issue-coordination.sh

echo
echo "verify-vf-class-a: PASS — wire parity locked on both sides, budgets green."
# HF3 (issue #737): the mutation-wire lock is complete — additive ops 0x04..0x0b, statuses 5/6,
# the 8-slot host handle table (file_table.zig parity), and both sides' encode/decode agree.
