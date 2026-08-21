# Claim: Trim hardware-contract.md to summary + actionable facts

- **Owner:** ox-alpha (`agent/ox-alpha/hygiene-trim-hardware-contract`)
- **Prompt / plan:** issue #270 (repo hygiene)
- **Scope:** docs-only — restructure `docs/hardware-contract.md`; archive the verbose narratives
- **Depends on:** —
- **Status:** ✅ done (`agent/ox-alpha/hygiene-trim-hardware-contract`)

## Notes

Issue #270: the file is 60K of verbose per-device discovery narratives; agents
read it for hardware constraints, not history. Plan:

1. Keep a **summary table** of device observations (device, PCI DID,
   reset-at-ExitBootServices behavior, key quirks) — ~50 lines.
2. Preserve the full pre-trim file verbatim as
   `docs/archive/hardware-contract-detail.md` (the issue #262 archive
   convention — nothing is lost, git + archive both hold it).
3. Keep only **actionable facts** (what to watch out for) in the main file.

Target: 57.9K → ~15–20K. Verification: byte-size before/after, no broken
inbound links (no doc links to anchors inside the file), coordination gate
green.
