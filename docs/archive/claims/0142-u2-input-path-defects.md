# Claim: three U2 input-path defects on main (CSI swallow, lone ESC, framebuffer erase)

- **Owner:** zcode (`agent/zcode/m8-u4-u5-on-main`)
- **Prompt / plan:** user request 2026-08-15 — compare the two independent
  milestone-eight U2/U3 implementations (this branch's, dropped in favour of
  the merged PR #114 work) and carry over only what is measurably better.
  Normative contract: ADR 0008 D2.
- **Scope:** `kernel/src/lineedit.zig` (the CSI decode state machine) and
  `kernel/src/text.zig` (the framebuffer console's byte stream). No
  re-litigation of U2/U3: the history ring, redraw strategy, completion
  depth, and error-shape helpers on `main` are left exactly as merged.
- **Depends on:** U2 (claim 1809, ✅ on main), G3 Road Pops (✅).
- **Status:** ✅ done (2026-08-15)

## Notes

Three defects found by diffing the two independent U2 implementations. All
three are in code paths the merged U2 owns; all three were absent from the
dropped branch's editor, which is why the comparison surfaced them.

1. **An unhandled CSI key leaked its final byte into the line.** In
   `feed`, escape state 2 reset to 0 for any final it did not act on, so
   `ESC [ 5 ~` (PageUp) left the `~` — a printable byte — to reach the
   insert path and appear in the line as text. Fixed by parsing the
   sequence properly: parameter bytes accumulate in `esc_param`, the final
   byte always ends the sequence, and only `~` with parameter 3 (Delete)
   acts. Multi-parameter sequences (`ESC [ 1 ; 2 D`) are swallowed whole.
2. **A lone ESC ate the following keystroke.** State 1 consumed the next
   byte unconditionally and returned `.none`, so `ESC` followed by any
   non-`[` byte silently lost that character. The byte is now re-fed
   through the normal path.
3. **Ctrl-L drew `[2J[H` on the framebuffer instead of clearing it.**
   `text.putc` had no escape handling, so the erase-in-display sequence
   that `lineedit`/`clear` emit was stored in the scrollback ring and
   rendered as glyphs. Only the serial console was ever correct here,
   because a real terminal consumes the sequence — which is why the U2
   live gate (serial + USB byte assertions) could not see it. `putc` now
   decodes CSI: `ESC [ 2 J` clears the layer, `ESC [ H` homes the cursor,
   any other sequence is swallowed rather than drawn.

## Verified

- ✅ Positive control first: the three new tests were run against pristine
  `origin/main` (`8076364`) in a separate worktree and **all three failed**
  there (`lineedit` 2 failed / 28 passed; `text` 1 failed / 26 passed), so
  each test demonstrably detects the defect rather than restating the fix.
- ✅ class A on this tree: `zig fmt --check` clean;
  `zig test kernel/src/lineedit.zig` 30/30; `zig test kernel/src/text.zig`
  27/27; `bash tools/verify-unit-tests.sh` all module suites pass;
  `zig build test-console` 409 tests + `verify-transcript` byte-identical;
  `zig build`, `zig build image`, `swift build` (host runner) ok;
  `bash tools/verify-coordination.sh` ok.
- ⬜ class B: not separately gated. The defects are host-observable by
  construction (a byte stream in, ring/line state out); the live surface
  they affect is covered by the existing `live-editing` gate, whose
  assertions are unchanged by this fix.
