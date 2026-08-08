#!/usr/bin/env bash
#
# verify-mmu-debt.sh -- claim 0022 gate: the MMU-debt boundary contract is
# intact. Deterministic (no VM, no build): it asserts that the documents and
# the kernel source that carry the no-TLBI safety argument still carry it,
# so the debt cannot be silently eroded.
#
# The kernel survives the VZ MMU takeover by omitting a TLBI (claim 0010).
# That is technical debt with a precise boundary (ADR 0006), NOT a completed
# VM subsystem. This gate fails CI if any of the load-bearing statements
# disappear:
#
#   1. ADR 0006 exists and lists the operations that invalidate the safety
#      argument (descriptor changes, permission changes, page reclamation,
#      non-identity mappings, ASID work, unmapping, above-blanket mappings,
#      TCR/MAIR changes).
#   2. ADR 0004 D3 records that the tlbi is NOT executed and points to
#      ADR 0006.
#   3. docs/hardware-contract.md records the VZ re-walk fault / no-TLBI
#      survival as [observed] and carries the "does not mean TLB
#      invalidation is proven" warning.
#   4. kernel/src/main.zig install_identity_map() still contains the no-TLBI
#      safety comment, the 4 GiB blanket constant, and the "map never
#      changes descriptors post-switch" statement — so re-adding a TLBI or
#      re-mapping code must update the contract in the same change or CI
#      fails.
#
# Usage: bash tools/verify-mmu-debt.sh
# Evidence saved under artifacts/mmu-debt-gate.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/mmu-debt-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

echo "=== verify-mmu-debt: claim 0022 — MMU-debt boundary contract intact (deterministic, no VM) ==="

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
echo "--- 1. ADR 0006 exists with the invalidation list ---"
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
check '**not** that TLB invalidation' 'ADR 0006 "not proven" warning' docs/decisions/0006-mmu-debt-boundary.md

echo
echo "--- 2. ADR 0004 D3 records the no-TLBI reality and points to 0006 ---"
check 'tlbi vmalle1' 'ADR 0004 D3 mentions the original tlbi (historical)' docs/decisions/0004-kernel-proper.md
check 'D3 addendum (2026-08-07, claims 0010/0020/0021' 'ADR 0004 D3 addendum present' docs/decisions/0004-kernel-proper.md
check '**ADR 0006**' 'ADR 0004 D3 points to ADR 0006' docs/decisions/0004-kernel-proper.md
check 'does **not**' 'ADR 0004 D3 "not proven" warning' docs/decisions/0004-kernel-proper.md

echo
echo "--- 3. hardware-contract records the VZ observations + warning ---"
check 'A TLBI-forced re-walk faults on VZ; omitting the TLBI survives' 'hardware-contract: TLBI re-walk fault [observed]' docs/hardware-contract.md
check 'does **not** mean TLB' 'hardware-contract: "not proven" warning' docs/hardware-contract.md
check '**ADR' 'hardware-contract: ADR 0006 pointer' docs/hardware-contract.md

echo
echo "--- 4. kernel install_identity_map() still carries the load-bearing comments ---"
KERNEL=kernel/src/main.zig
check 'NO `tlbi vmalle1` at the switch' 'kernel: no-TLBI comment' "$KERNEL"
check '4 * 1024 * 1024 * 1024' 'kernel: 4 GiB blanket constant' "$KERNEL"
check 'map never changes descriptors' 'kernel: descriptors-immutable statement' "$KERNEL"
check 'stale firmware TLB entries' 'kernel: stale-TLB safety argument' "$KERNEL"

if [ "$FAIL" = 1 ]; then
    echo
    echo "verify-mmu-debt: FAILED — the MMU-debt boundary is eroded; fix the contract before merging."
    sleep 0.5
    exit 1
fi
echo
echo "verify-mmu-debt: PASS — MMU-debt boundary contract intact (ADR 0006 + ADR 0004 D3 + hardware-contract + kernel comments)."
sleep 0.5
exit 0
