# Log — M1.5 console & shell core (agent B)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-06** — **Claim (buffy,
  `freebuff/milestone-1-5-console-shell-core-agent-b-rx-read-p-2ee77bfe-eac9-4018-b5e1-ea38a0080268`):**
  claimed the M1.5 console & shell core row (steps 9–11 + prompt loop). Per
  the B-prompt process gate: design written first
  (`docs/m15-shell-core-design.md`), code in new `kernel/src/*.zig` modules
  (`lineedit.zig`, `tokenizer.zig`, `shell.zig`) plus the `console.zig` read
  path, mock-console based; `kernel/src/main.zig` gets only the prompt-loop
  seam. 🔄 in progress — no code written yet. (Coordination note: this
  branch's base predated the claims/logs split, so the claim was first
  registered in the `docs/status.md` table; it is re-registered here on the
  current coordination surface — see `docs/m15-shell-core-design.md` §0.)
- **2026-08-06** — **M1.5 console & shell core slice done (buffy,
  `freebuff/milestone-1-5-console-shell-core-agent-b-rx-read-p-2ee77bfe-eac9-4018-b5e1-ea38a0080268`):**
  implemented and host-tested the interactive shell core. `console.zig`
  gained a polled `readByte` vtable slot + a scripted `MockConsole` input
  queue (`feed`/`readByte`, overflow-flagged); new `lineedit.zig` (256-byte
  bounded editor: CR/LF submit, CRLF pair = one line, backspace, Ctrl-C
  cancel, overflow refused with bell), `tokenizer.zig` (≤ 17 tokens,
  double-quoted strings, explicit unbalanced-quote and too-many behavior),
  `shell.zig` (banner → `dipshit> ` prompt → read → tokenize →
  `monitor.exec`, WFE-park fallback, mock-fed end-to-end transcript test).
  `kernel/src/main.zig` gained only the prompt-loop seam; the takeover path
  is byte-identical (gate 5, verified by diff). **Observed:** `zig fmt
  --check` pass, `zig build`/`image`/`inspect`/`context` pass (no
  regression), `zig test` green for all 7 modules via
  `bash tools/verify-unit-tests.sh` (per-module gate output: console 10,
  handoff 3, lineedit 19, memmap 5, monitor 41, shell 65, tokenizer 50 —
  counts include transitively imported tests), mock-fed loop
  transcript asserted byte-for-byte — evidence
  `artifacts/m15-shell-core-{fmt,build,tests,loop,transcript,diff,coord}.txt`.
  `tools/verify-unit-tests.sh` MODULES list extended with the three new
  modules. **Not claimed:** live RX and end-to-end keystroke → command —
  gated on the VZ serial gate (claim 0002, 🔄); the kernel adapter's
  `readByte` is an `[inferred]` no-RX stub, no device register read. ✅ —
  mock-tested, hardware unclaimed.
