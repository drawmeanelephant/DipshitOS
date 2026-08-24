# Log — agent/ox-alpha/m25-filemanager-depth

Append-only. One entry per unit of work; corrections are new entries
that reference the old one.

---

## 2026-08-23 — claims 0434 (Lane A) + 2539 (Lane B) opened

M25 file-manager depth, both lanes, sequential on this branch (the
lanes share `user/src/file_browser.zig`; one editor per file honored by
doing them in order).

Pre-flight findings recorded before any code:

- **Stale issue states upstream:** F11 closed correctly, but F12 (#392,
  hidden toggle) and F16 (#396, path copy) are already implemented on
  `main` (commit `658bd86`, PR #512) while their issues remain open.
  Will verify against HEAD and close with evidence pointers at the end.
- **F3 card is wrong about scope:** issue #383 says directory creation
  "uses existing `sys_file_create` (slot 25)" with no kernel work, but
  `ATTR_DIRECTORY` appears nowhere under `kernel/src` — there is no FAT32
  directory-create path today. Lane B therefore includes kernel-side
  directory creation (cluster allocation + zeroed cluster + `.`
  / `..` dot entries + ATTR-directory dir entry), extending slot 25's
  contract instead of minting a new slot (ABI budget: 56/64 used).
- `docs/march-m25.md` only tracks F1–F5; F6–F18 exist solely as GitHub
  issues. March file will be updated for the cards this branch lands;
  the rest stays open for follow-up claims.

Claims: [`docs/claims/0434-m25-lane-a-bulk-props.md`](../claims/0434-m25-lane-a-bulk-props.md),
[`docs/claims/2539-m25-lane-b-mkdir-du-recent.md`](../claims/2539-m25-lane-b-mkdir-du-recent.md).
Indexes refreshed.
