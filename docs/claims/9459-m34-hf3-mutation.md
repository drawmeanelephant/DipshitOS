# Claim: M34 HF3 — mutation ops over the host file channel (issue #737)

- **Owner:** buffy (`agent/buffy/m34-hf3-mutation`)
- **Prompt / plan:** M34 (milestone #21) issue #737; HF1+HF2 are merged
  (PR #745, claim 7710 — queue 5 wire + `vf ls`/`vf cat` live-proven).
  Tracker `docs/host-file-channel-scoping.md`.
- **Scope:** OPEN/CLOSE/WRITE/TRUNCATE/RENAME/MKDIR/DELETE/FSYNC over
  queue 5, served by plain Swift `FileManager`/`FileHandle` calls rooted
  at the `--cvc-file` share with the existing path defense; an 8-slot host
  handle table (parity with `file_table.zig`'s 8-handle ABI live on the
  HOST side, where write cursors earn their keep: cursor advance, append
  writes, read-modify-write truncate); additive opcodes (0x04–0x0B) so the
  protocol stays non-breaking; honest caps + error status mapping (not
  found / is a directory / exists / handle limit / host error); class-B
  gate writes from the guest and verifies the file ON THE HOST DISK,
  FSYNC survives a reboot read-back.
- **Touches:** `kernel/src/virtio_file.zig` (open/close/write/truncate/
  fsync/rename/mkdir/delete encode + decode + `exchange_raw` refactor +
  BSS write staging), `kernel/src/monitor.zig` (`vf open/close/write/
  truncate/fsync/mkdir/rm/mv` + status text), `host/vm-runner/Sources/
  VFWire/VFWire.swift` (constants + encode/decode + VZ-free
  `FileHandleTable`), `host/vm-runner/Sources/VMRunner/main.swift` (queue-5
  mutation service), `host/vm-runner/Tests/VMRunnerTests/VFWireTests.swift`
  (wire parity + table tests), `kernel/src/shell.zig` + `tests/
  transcript-console.txt` (vf help line), `tools/verify-live-vf.sh` (HF3
  phases), `tools/verify-vf-class-a.sh` (test-listing comment), `docs/
  hardware-contract.md` (wire table), claim + branch log; claim id via
  `bash tools/status/claim-id.sh`.
- **Not touching:** HF4/HF5/HF6/HF7 cards — no exec-from-share, no user-data
  migration, no FAT removal, no CLONE. The guest surface is monitor `vf`
  commands only; apps and persistence stay where they are.
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done