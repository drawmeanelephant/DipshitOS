# Claim: milestone ten, card F2 — path canonicalization & partition routing

- **Owner:** buffy (`agent/buffy/m10-fs`)
- **Prompt / plan:** `docs/march-m10.md`
- **Scope:** Milestone 10 card F2: safe userland path parsing, prefix routing (`/esp/` -> ESP, `/data/` -> DATA, bare paths -> DATA), traversal defense (`..` rejection), and 8.3 / FAT path normalization.
- **Depends on:** F0, F1
- **Status:** ✅ done (2026-08-15)

## Notes

Implements path resolution and partition routing in `kernel/src/file_table.zig`:
- Parses volume prefix (`/esp/`, `/data/`, bare paths).
- Sanitizes multiple consecutive slashes and strips leading/trailing delimiters.
- Rejects forbidden directory traversal patterns (`..`).
- Normalizes components to 8.3 FAT format.

## Verified

- Gate: Class A unit tests covering path canonicalization, volume routing, and traversal defense in `kernel/src/file_table.zig`.
