# Log — milestone eight cards U4+U5: pointer focus/cursor + window HIG (zcode)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-14** — **Claim (zcode, `agent/zcode/m8-u4-u5-windows`):** claimed
  the U4+U5 pair as one owner per the march-m8 split (both cards share the
  Driving Award compositor). Claims: `docs/claims/0935-u5-window-hig.md` +
  `docs/claims/4993-u4-pointer-focus-cursor.md`. U5 first (U4 depends on its
  indicator work). Chord decision recorded: HID Alt+Tab decode host-tested;
  the live gate cycles via `win cycle` over serial (the U2 synthesized-
  modifier limitation, already in the hardware contract). Branched from the
  U3 branch. 🔄 in progress — no code written yet.
- **2026-08-14** — **U5 done + U4 blocked (zcode,
  `agent/zcode/m8-u4-u5-windows`):** U5 (claim 0935) — the D4 chrome:
  the white 3-px focus ring on the focused window (focus()/cycle/raise
  now repaint), user-window title bars (name + owning pid) drawn in the
  compositor's chrome pass (EL0 back-buffers untouched), `win cycle` +
  the host-tested Alt+Tab HID decode for keyboard cycling. Gate
  `tools/verify-live-win-hig.sh` PASS 8/8 on VZ (scale-aware pixel
  proof; the capture arrived at 1x this session — the sampler detects
  it). U4 (claim 4993) — the guest side (click=focus+raise, the magenta
  cursor, the axis mapping, Alt+Tab) is host-tested and the runner
  pointer seam landed, but the LIVE proof is blocked: five synthesized
  delivery routes all produced ptr-reports=0 (hardware contract; the
  keyboard seam does translate — the asymmetry is recorded). En-route
  fix: a latent OOB write in text.zig's render (tiny-canvas host test)
  found via a bus error after BSS layout shifts — render is now
  canvas-bounded (pre-existing on main; worth an upstream note).
- **2026-08-15** — **rebased onto main; three U2 defects carried over
  (zcode, `agent/zcode/m8-u4-u5-on-main`):** the U4/U5 pair was reconciled
  onto `origin/main` `8076364` after PR #114 landed an independent U2/U3 and
  PR #129/#130/#131 landed the glyph bit-order fix. This branch's competing
  U2/U3 commits are DROPPED — upstream's stand. `win cycle` now reports
  misuse through main's `print_usage`/`err_prefix` and registers in
  `sub_verb_complete`; the win help/usage strings, the shell help golden and
  `tests/transcript-console.txt` gained the sub-verb line. The compositor's
  `draw_glyph` inherits `font8x8.row_pixel`, so the chrome text is no longer
  mirrored: the live capture decodes forward with `fwd_unknowns=0` against
  `mir_unknowns=314`. Live gate re-run post-rebase:
  `verify-live-win-hig` PASS (ring=1 edge_not_ringed=1 title=1).
  Comparison of the two U2/U3 implementations found three defects on main
  that the dropped branch did not have — claim 0142 fixes them (unhandled
  CSI finals leaking `~` into the line, a lone ESC eating the next
  keystroke, and Ctrl-L drawing `[2J[H` on the framebuffer instead of
  clearing it), each with a positive control against pristine main. The
  rest of the dropped work (history ring shape, redraw strategy, two-level
  completion, the D3 helper set) is deliberately NOT carried over.
- **2026-08-15** — **carried the better half of the duplicated U2/U3 over
  (zcode, `agent/zcode/m8-u4-u5-on-main`):** cards U2/U3 exist twice —
  PR #114's merged version and this branch's unpushed one. Instead of
  discarding the unmerged work, both were scored against ADR 0008 and the
  measurable wins carried over (claim 3552, after claim 0142's three
  input-path defects). D3: shape 1 now carries the required one-line hint
  at all 29 misuse sites (registry blurb — one source, no drift); the four
  dispatch/line-level refusals (`exec` empty argv + over-long argv, the
  shell's tokenizer refusal and over-long-line refusal) moved onto shape 2
  with ONE shared too-many message; the canonical transcript gained a D3
  section so all three shapes are gate-tested byte-exactly. Enforcement is
  now mechanical: two registry-walk tests (exact misuse shape; garbage-argv
  refusals shape-checked line by line) replace convention, and they
  immediately caught two real leaks main's no-panic fuzz could not see —
  `mbox` (claim 5965, added after U3's sweep) and `beans`. D2: the live gate
  drove ZERO of the six required Ctrl chords; a second serial-byte phase
  now proves Ctrl-A/E/K/U/L/C end to end (the bytes input.zig's HID decode
  emits; synthesized USB modifiers never reach VZ), each by the command it
  causes to run, with the Ctrl-C-cancelled line asserted never to execute.
  That needed one runner fix: `forwardScriptOnce`'s marker wait was capped
  at 40 s and phase 2's marker lands ~100 s in, so the bound now extends to
  the session `--timeout`. First gate run failed honestly (chords all 0)
  from that cap; re-run PASS. Deliberately NOT carried over: main's history
  ring, redraw strategy, completion depth and helper set are style, not
  contract. Open question left for review in claim 3552: D3's text spells
  shape 3 with an em dash the framebuffer cannot render — code keeps ASCII
  `--`, the ADR text probably wants amending.
