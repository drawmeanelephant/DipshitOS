#!/usr/bin/env bash
#
# verify-mmu-debt.sh -- claim 1517 gate: the MMU takeover contract is
# intact. Deterministic (no VM, no build): it asserts that the documents and
# the kernel source that carry the takeover contract still carry it, so the
# corrected-translation + full-invalidation design cannot be silently
# eroded.
#
# Claims 6460/7896 proved on real VZ hardware that the old no-TLBI crutch
# (ADR 0006, claim 0010) only survived by riding stale firmware TLB entries
# and that the underlying translation start-level was wrong (T0SZ=25/W=39
# starts the 4 KiB walk at level 1 over the L0-rooted tables -> every fresh
# walk faults). Claim 1517 pays the debt: production programs T0SZ=16
# (correct start level) and executes `tlbi vmalle1; dsb ish; isb` at the
# switch. This gate fails CI if any of the load-bearing statements disappear:
#
#   1. ADR 0006 exists, records the invalidation list (descriptor changes,
#      permission changes, page reclamation, non-identity mappings, ASID
#      work, unmapping, above-blanket mappings, TCR/MAIR changes) that
#      remains binding, and carries the claim-1517 supersession note.
#   2. ADR 0004 D3 records the corrected start level + TLBI-at-switch
#      (claim 1517) and points to ADR 0006.
#   3. docs/hardware-contract.md records the corrected start level + TLBI
#      and the post-MMU virtio TX as [observed].
#   4. kernel/src/mmu.zig install_identity_map() still contains the TLBI +
#      corrected-start-level comment, the 4 GiB blanket constant, and the
#      "map never changes descriptors post-switch" statement — so removing
#      the invalidation or re-mapping code must update the contract in the
#      same change or CI fails.
#
# Usage: bash tools/verify-mmu-debt.sh
# Evidence saved under artifacts/mmu-debt-gate.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/mmu-debt-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

echo "=== verify-mmu-debt: claim 1517 — MMU takeover contract intact (corrected start level T0SZ=16 + TLBI at the switch; deterministic, no VM) ==="

FAIL=0
check() { # needle description file
    local needle="$1" desc="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  PASS: $desc"
    else
        echo "  FAIL: $desc (missing from $file)"
        FAIL=1
    fi
}

echo
echo "--- 1. ADR 0006 exists with the invalidation list + supersession note ---"
[ -f docs/decisions/0006-mmu-debt-boundary.md ] && echo "  PASS: docs/decisions/0006-mmu-debt-boundary.md exists" || { echo "  FAIL: ADR 0006 missing"; FAIL=1; }
for needle in \
    'Descriptor changes' \
    'Permission/attribute changes' \
    'Page reclamation' \
    'Non-identity mappings' \
    'ASID / address-space work' \
    'Unmapping' \
    'Mappings above the blanket' \
    'TCR/MAIR changes'; do
    check "$needle" "ADR 0006 invalidation item: $needle" docs/decisions/0006-mmu-debt-boundary.md
done
check 'MMU debt boundary' 'ADR 0006 title' docs/decisions/0006-mmu-debt-boundary.md
check 'claim 1517' 'ADR 0006 supersession note (claim 1517)' docs/decisions/0006-mmu-debt-boundary.md

echo
echo "--- 2. ADR 0004 D3 records the corrected start level + TLBI and points to 0006 ---"
check 'T0SZ=16' 'ADR 0004 D3 records the corrected start level (T0SZ=16)' docs/decisions/0004-kernel-proper.md
check 'tlbi vmalle1' 'ADR 0004 D3 mentions the tlbi (historical + claim 1517)' docs/decisions/0004-kernel-proper.md
check 'claim 1517' 'ADR 0004 D3 claim-1517 addendum present' docs/decisions/0004-kernel-proper.md
check '**ADR 0006**' 'ADR 0004 D3 points to ADR 0006' docs/decisions/0004-kernel-proper.md

echo
echo "--- 3. hardware-contract records the corrected MMU + post-MMU TX observations ---"
check 'T0SZ=16' 'hardware-contract: production T0SZ=16' docs/hardware-contract.md
check 'tlbi vmalle1' 'hardware-contract: TLBI at the switch' docs/hardware-contract.md
check 'post-MMU virtio' 'hardware-contract: post-MMU virtio TX [observed]' docs/hardware-contract.md
check '**ADR' 'hardware-contract: ADR 0006 pointer' docs/hardware-contract.md

echo
echo "--- 4. kernel install_identity_map() still carries the load-bearing comments ---"
KERNEL=kernel/src/mmu.zig
check 'tlbi vmalle1' 'kernel: TLBI executed at the switch' "$KERNEL"
check 'claim 1517' 'kernel: claim-1517 TLBI comment' "$KERNEL"
check '4 * 1024 * 1024 * 1024' 'kernel: 4 GiB blanket constant' "$KERNEL"
check 'map never changes descriptors' 'kernel: descriptors-immutable statement' "$KERNEL"

if [ "$FAIL" = 1 ]; then
    echo
    echo "verify-mmu-debt: FAILED — the MMU takeover contract is eroded; fix the contract before merging."
    sleep 0.5
    exit 1
fi
echo
echo "verify-mmu-debt: PASS — MMU takeover contract intact (T0SZ=16 + TLBI at the switch; ADR 0006 + ADR 0004 D3 + hardware-contract + kernel comments)."
sleep 0.5
exit 0
