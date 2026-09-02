# Claim: M34 HF7 — CLONE → clonefile COW dedup (worktree workload) (issue #741)

- **Owner:** buffy (`freebuff/get-git-up-to-date-there-were-quite-a-few-things-d-fe3ff43a-1217-4ca3-a9ad-b6faa6fbe86f`)
- **Prompt / plan:** implement M34 HF7 (#741): the last card of milestone
  #21 (M34 — FAT-free storage). The host file channel gains a **CLONE
  opcode (0x0c)** mapped to APFS COW cloning — `clonefile(2)` for regular
  files and `copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE |
  COPYFILE_RECURSIVE` for directory trees (the man page explicitly prefers
  copyfile(3) for directories) — with the same traversal defense every VF
  op uses. Guest surface: `vf clone <from> <to>` (monitor). Deliverable:
  a worktree-clone workflow proven LIVE on VZ with a host-side space
  measurement saved under `artifacts/`: N clones of a repo fixture measurably
  consume far less volume than N `cp` copies, and an edit in one worktree
  does NOT duplicate untouched siblings (byte-compare + a tiny edit delta).
  Plus the documented alternative: point the share at a ZFS (or APFS
  snapshot) volume for true block-level dedup/snapshots, inherited with
  zero guest code.
- **Measurement honesty (empirical, observed on this host):** `du` CANNOT
  see clone savings — it reports logical per-file size (repo + clone + cp
  all report 6148 KB for a 6 MiB fixture) because `st_blocks` is not
  discounted for clone sharing. The gate therefore measures PHYSICAL
  used-space deltas at the volume level (`os.statvfs` before/after each
  window): one clone measured ~0 delta while one `cp` measured +6.0 MiB.
  Both numbers go in the artifact; the gate asserts clones ≪ copies with
  the raw numbers shown, never an expected constant.
- **Wire:** opcode `0x0c` (additive, after DELETE `0x0b` — old hosts answer
  host-error, old guests never send it). Payload mirrors RENAME:
  `[from][0x00][to]`. dst must NOT exist → maps to `st_exists` (5);
  missing src → `st_not_found`; clonefile EEXIST mirrors the pre-check;
  failure → `st_host_error`. No new BSS (clone rides the existing
  `exchange` path's request buffer; no new buffers, no new handles).
- **Touches:** `kernel/src/virtio_file.zig` · `kernel/src/monitor.zig` ·
  `host/vm-runner/Sources/VFWire/VFWire.swift` ·
  `host/vm-runner/Sources/VMRunner/main.swift` ·
  `host/vm-runner/Tests/VMRunnerTests/VFWireTests.swift` ·
  `tools/verify-live-vf.sh` ·
  `docs/hardware-contract.md` · `docs/host-file-channel-scoping.md` ·
  `docs/status.md` · `docs/claims/1312-m34-hf7-clone-dedup.md` ·
  `docs/logs/agent-buffy-m34-hf7-clone-dedup.md`
- **Depends on:** HF3 (mutation wire — CLONE rides the same exchange
  framing) — landed
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done — live gate PASS 6/6 (run 6, 2026-09-02), measurement artifact under `artifacts/m34-hf7-measurement.txt`; flake #810 filed (boot EL0 probe hang/park, 8/24 boots this session, retried in-gate)

## Notes

Acceptance gate (issue #741): live + host measurement — creating N
worktrees via CLONE shows measured space savings vs copies (du before/after
under `artifacts/`), and an edit in one worktree does NOT duplicate
untouched sibling files; savings shown, not asserted blindly. Verification:
class-A (fmt/build/unit/swift-test/BSS) + the extended `verify-live-vf.sh`
(clone + edit phases appended to the existing 4) on VZ, with
`artifacts/m34-hf7-measurement.txt` carrying the raw before/after deltas.