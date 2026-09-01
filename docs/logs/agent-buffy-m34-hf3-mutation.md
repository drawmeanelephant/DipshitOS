# Log — M34 HF3 mutation ops (issue #737)

Branch: `agent/buffy/m34-hf3-mutation` · Worktree: `../dipshitos-buffy`
Claim: [9459](../claims/9459-m34-hf3-mutation.md)

### 2026-09-01 — claim filed, wire studied, plan set
HF1+HF2 landed (PR #745); HF3 takes the mutation verbs. Wire stays
additive (opcodes 0x04–0x0B; unknown op already answers status 4 host
error, so old hosts/new guests and new hosts/old guests both degredate
honestly — no version churn). Design decisions pinned here for the review:

- **Handles live on the HOST** (parity with `file_table.zig`'s 8-handle
  ABI — `max_file_handles = 8` asserted on both sides): the HF2 stateless
  ideal yields exactly where cursors earn their keep (append writes,
  read-modify-write, truncate). OPEN/CLOSE/WRITE/TRUNCATE/FSYNC are
  handle-based; RENAME/MKDIR/DELETE stay path-based stateless. The host
  table is a VZ-free `FileHandleTable` in the VFWire module so the 8-slot
  cap + cursor/append/truncate semantics are unit-testable on any host.
- **Monitors**: `vf open <path> [append]`, `vf close <h>`, `vf write <h>
  <n>` (writes n bytes of the deterministic probe `pattern(i)` — the
  gate's python computes the same bytes), `vf truncate <h> <n>`,
  `vf fsync <h>`, `vf mkdir <path>`, `vf rm <path>`, `vf mv <from> <to>`.
- **Gate shape (3 boots)**: (1) mkdir+open+write 100,000 pattern bytes in
  4 chunks+fsync+close+rename+append-open+4-byte append — host python then
  byte-compares the file on disk; (2) reboot read-back `vf cat` proves
  FSYNC durability; (3) `vf rm` + mkdir-exists honest error, host verifies
  gone. `verify-live-vf.sh` neck: `BOOTS=3` run PASS.
### 2026-09-01 — HF3 complete: all eight verbs live-proven, host disk is the oracle
Guest + host + gates landed in one PR:

- **Wire (additive 0x04..0x0b):** OPEN/CLOSE/WRITE/TRUNCATE/FSYNC ride the
  host's VZ-free `FileHandleTable` (8 slots = file_table.zig parity,
  S8–S10 unit tests: cursor advance, truncate clamp, append-at-EOF, cap +
  slot reuse); RENAME/MKDIR/DELETE are stateless path ops. Status 5
  (exists) + 6 (handle) added on both sides (G7–G12, S5–S7 wire parity).
- **Guest surface:** `vf open <path> [append] | close <h> | write <h> <n>
  (probe-pattern stream, chunked ≤32763 B) | truncate <h> <n> | fsync <h>
  | mkdir <path> | rm <path> | mv <from> <to>`; honest status text.
- **Gates:** `verify-live-vf` 3/3 PASS on VZ — mutate boot writes 100,000
  pattern bytes in 4 chunk round trips + renames + 4-byte append; python
  byte-compares the file ON THE HOST DISK (100,004 B match); read-back
  boot re-streams with matching cksum (FSYNC durability across reboot);
  delete boot removes it, mkdir exists-error asserted, host verifies gone.
  virtio-e2e + ps regressions green; class-A + BSS (562 KiB headroom)
  green.

Debugging notes for the record (all resolved):
- The gate's first live runs HUNG instead of failing — the combined-phase
  script builder did `cat SCRIPT_MUTATE >> script-mutate.txt` (a
  SELF-APPEND, the dest aliased the source): `cat f >> f` grows forever.
  Traced with `bash -x`; fixed by naming the combined file `*-combined.txt`.
- The append handle is NOT deterministic: the host reuses freed slot 0, so
  the script kept h=0 open across the rename to force the append into
  slot 1 (this mirrors real cursor semantics instead of a fixed fd).
- Tool-call timeouts were killing backgrounded gates mid-run; the gate now
  runs foreground within the tool budget (~4 min for 3 boots).
