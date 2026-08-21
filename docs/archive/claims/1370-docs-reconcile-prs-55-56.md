# Claim: Reconcile docs with the merged PRs #55 + #56 (real IRQ delivery + custom-virtio)

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** docs-only mission 2026-08-10 — "One docs-only PR, no code changes: update docs/status.md (milestone table — real IRQ delivery done, item 6 flipped, macOS 27+ floor, 21 commands), docs/hardware-contract.md (GIC/timer [observed] with the corrected SGI-frame offsets; custom-virtio discovery [observed]), and docs/roadmap.md milestone-3 ordering; refresh indexes and keep the coordination gate green."
- **Scope:** docs only — `docs/status.md`, `docs/hardware-contract.md`, `docs/roadmap.md`, and the generated coordination indexes. No code changes.
- **Depends on:** merged `main` 3436676 — PR #55 (claim 9187, real VZ IRQ delivery), PR #56 + #57/#58 (the custom-virtio spike branch: claims 5844/0828/4374/9492/9737/4837/5275). The working tree is exactly `origin/main`.
- **Status:** ✅ done 2026-08-10 — docs reconciled against merged `main` 3436676 (PRs #55/#56/#57/#58): status.md's milestone-table real IRQ delivery / item-6 flip / macOS 27+ floor verified, hard-gate command count corrected to the merged **22** (20 → 21 via `pci`/claim 5844, → 22 via `tasks`/claim 5275 — the mission's "21" predates claim 5275); hardware-contract.md gained the custom-virtio discovery **[observed]** (host-device bullet + dedicated section: DID 0x1082, BAR0 `0x100020000`, firmware-disabled PCI command register, SPI 69 used-ring IRQ, VZ feature surface, per-burst IRQ coalescing, two split-ring queues); roadmap.md gained an ordered **Milestone three** section (allocator → exception vectors → GIC + timer → tasks → userspace). Coordination indexes regenerated; `verify-coordination.sh` green; no code touched.

## Notes

Most of the mission's status.md checklist already landed inside the code
commits (ed2a3ac flipped the milestone-table row and item 6 for claim 9187;
e57362a set the macOS 27+ floor and the 21-command count; f649b9e
documented the tasks card). This claim verifies those and fills the
genuine gaps:

1. **`docs/status.md`** — verified present: milestone-table real IRQ
   delivery (claim 9187, 3/3), item 6 flipped, macOS 27+ floor.
   **Correction:** the mission's "21 commands" predates claim 5275's
   `tasks` command — the merged registry is **22** (`registry_count` in
   `kernel/src/monitor.zig`; branch log records "registry 21→22"), so the
   hard-gate count is updated to 22 with the provenance (20 → 21 via
   `pci`/claim 5844, → 22 via `tasks`/claim 5275).
2. **`docs/hardware-contract.md`** — the GIC/timer `[observed]` entries
   with the corrected SGI-frame offsets (`GICR+0x10080`, claim 9187) were
   already in place; the **custom-virtio discovery `[observed]`** (VID
   0x1af4 / DID 0x1082, BAR0 `0x100020000`, firmware leaving the PCI
   command register disabled, real SPI 69 used-ring IRQ, VZ's feature
   negotiation surface, per-burst IRQ coalescing; claims
   5844/0828/4374/9492/9737/4837) was missing and is added, both as a
   host-device bullet and as a dedicated section.
3. **`docs/roadmap.md`** — the milestone-three cards sat under "Later
   milestones (sketches only, not commitments)"; they are now presented as
   an ordered **Milestone three** section (physical allocator → exception
   vectors → GIC + timer → kernel tasks → userspace next), matching the
   canonical ordering in `docs/status.md`.

Gate: `bash tools/status/refresh-indexes.sh` then
`bash tools/verify-coordination.sh` (must stay green; also runs in CI).
