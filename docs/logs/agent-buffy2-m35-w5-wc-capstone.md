# Log — M35 W5 — the ecosystem capstone: wc (issue #766)

## 2026-09-02 — W5 filed (claim 5883, issue #766)

Claim + plan + this log created in the `../virelaios-buffy2` worktree:
`docs/claims/5883-m35-w5-wc-capstone.md`, `docs/march-m35-w5-wc-capstone.md`,
this file. Depends on W4 (claim 7395, DONE 2026-09-02). Plan: wc app
(tests/wc.c from the contract doc alone) → pinned wc.wasm → host test with
a capture file-data simulation → live-gate W5 phase → docs flips. W5 is
Milestone #22's last card; closing it makes M35 6/6.
## 2026-09-02 — W5 DONE: the wc capstone ships + gates (claim done, Milestone #22 6/6)

- **The app (tests/wc.c):** written from docs/wasm-import-contract.md +
  tests/virelai.h alone (the standalone-author provenance proof — the
  "fresh host author" is this claim). Reads /host/WC.TXT via
  env.file_open/file_read/file_close in 64-byte chunks (§5.1: open with
  MODE_READ on a byte-slice path, n<=0 at EOF, negative = -errno §4),
  counts bytes/lines/words with an in-word whitespace state machine that
  survives chunk seams, prints the classic right-aligned wc line, exits
  with the byte count (fileapp's length proof). Error statuses 41/42.
- **Deterministic fixture (tests/wc-fixture.txt):** 320 bytes, 8 lines,
  32 words — the long-token line (>64 B) forces word-state across chunk
  seams (4 seams verified); a \r\n line and tab-columns exercise ws
  variety; counts cross-validated against host `wc -lwc` (agrees: 8 32
  320). Expected line: `  8  32 320 /host/WC.TXT` (width = widest count).
- **Authoring honesty:** the native cross-run harness
  (`cc -DVIRELAI_NATIVE`) caught TWO bugs before anything was pinned:
  (1) `put_pad` indexed uninitialized tmp[] past the digits after
  padding (single shared counter), (2) the path write's length was 15
  for a 14-byte literal (+NUL). Native now byte-matches the expected
  line exactly; the pinned wasm came after.
- **Pinned:** user/src/wasm-corpus/wc.wasm, sha256
  b75c504ddbb30b8ada6244cb95d3aaf532c49f79a45e7a68dc02151211e7746c
  (1,955 B), rebuild-byte-identical; imports exactly env.*
  (file_open/write/exit/file_close/file_read), _start exported.
- **Host test (wasm.zig, 39/39):** `HostCapture` gained
  file_data/file_pos — captured file_read now SERVES fixture bytes via
  stageOut (0 at EOF, cap-clamped, §5-faithful) so a file-channel app
  executes end-to-end in a host test. The W5 test runs wc: parse ->
  validate -> instantiate (zeroed store; fresh-memory-zero per spec) ->
  call; asserts the exact 22-byte line, exited, status 320, and >=5
  chunk reads (5x64 + EOF probe).
- **Live gate (verify-live-wasm.sh W5 phase):** WC.WASM pinned + copied,
  WC.TXT = tests/wc-fixture.txt (one source of truth), exec'd between
  HELLO and WINAPP in script1 (all short non-display apps, winapp keeps
  <=1 overlap). Per run asserts the byte-exact line, `tasks user-exec
  exited status=320`, and rx-w5-wc. **Live class-B gate PASS boot1
  (rc=0)**: wcline=1 wcexit=1 wcresp=1, all W2/W3/W4 needles intact
  (red fill 10,436 px, fileapp 512, floatapp 590, hello 55) — serial
  evidence artifacts/live-wasm-serial-boot1.log (the 3-space-padded line
  raw, status 320, procs WASM.BIN exited status=320).
- **One flaky boot bracketed:** the first gate attempt hit the known M34
  VZ-error class (state=3 early VM stop after ALL guest work completed —
  issue #803's sibling flake; the guest never faulted) and the rerun
  PASSed cleanly; the fail+pass pair is logged honestly (both serials
  under artifacts/).
- **Docs flipped:** contract §7 gained the worked-author example mapping
  doc sections -> wc.c lines (the provenance proof); scoping card W5 row
  ✅ + what-W5-landed note; status.md M35 row ✅ 6/6 (open-workstreams
  pointer closed); plan doc STATUS. **Milestone #22 is 6/6 — the
  milestone + tracker closure ride the PR merge (owner action).**
