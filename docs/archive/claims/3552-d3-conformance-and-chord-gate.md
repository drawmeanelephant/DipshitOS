# Claim: D3 shape conformance + the live Ctrl-chord phase (carry-over from the duplicated U2/U3)

- **Owner:** zcode (`agent/zcode/m8-u4-u5-on-main`)
- **Prompt / plan:** user request 2026-08-15 — cards U2/U3 were implemented
  twice independently (this branch's version, and the PR #114 version that
  merged first because this branch could not be pushed). Rather than discard
  the unmerged work, compare both against ADR 0008 and carry over everything
  measurably better. Normative contract: ADR 0008 D2 + D3.
- **Scope:** `kernel/src/monitor.zig` (D3 shape 1's hint, dispatch-level
  shapes, two leaked handler shapes, the mechanical registry-walk tests),
  `kernel/src/shell.zig` (line-level refusals, the gated transcript's D3
  section, the host chord-stream test), `tests/transcript-console.txt`
  (regenerated), `tools/verify-live-editing.sh` (a second phase proving all
  six D2 chords), `host/vm-runner/.../main.swift` (the marker-wait bound that
  a two-phase gate needs). NOT in scope: replacing main's history ring,
  redraw strategy, completion depth, or helper set — those are style, not
  contract, and main's versions are gated and working.
- **Depends on:** U2 (claim 1809, ✅), U3 (claim 1511, ✅), claim 0142 (the
  three input-path defects, same branch).
- **Status:** ✅ done (2026-08-15)

## Notes

ADR 0008 D3 says misuse is `usage: <cmd> <args>` **plus a one-line hint**,
and that "the misuse and error transcripts are themselves gate-tested (card
U3), so a new command that prints a fourth shape fails CI". Measured against
that text, `main` had four gaps; the unmerged branch had closed all of them.

1. **Shape 1 had no hint.** `print_usage` printed only the usage line, at all
   29 misuse sites. It now appends the command's registry blurb — one source
   for the hint, so no per-handler copy can drift.
2. **The dispatch layer printed unsanctioned shapes.** `exec`'s empty-argv and
   over-long-argv refusals, the shell's tokenizer refusal, and its
   over-long-line refusal were bare sentences with no shape prefix. All four
   now take shape 2, and `exec` + the shell share ONE too-many message so the
   two paths cannot drift. An empty line is deliberately shape 2 rather than
   shape 3: there is no verb to quote, so `unknown command ''` would be a lie.
3. **The enforcement was not mechanical.** `main`'s U3 fuzz proves no handler
   panics, which is valuable and kept, but it never checks output SHAPE, so
   drift is invisible. Two registry-walk tests now do: one asserts every
   misusable command's misuse output is EXACTLY usage+hint, the other feeds
   garbage argv to every command and fails on any refusal line that is not
   one of the three shapes. They immediately caught two real leaks — `mbox`
   (claim 5965, added after U3's sweep, printing `mbox: invalid pid: ...`)
   and `beans` (`beans: count must be between ...`). Both now wear `error:`.
   A curated list of commands could not have caught either, because neither
   command would have been on it.
4. **The three shapes are now gate-tested byte-exactly.** The canonical
   transcript gained a D3 section — shape 1 with its hint, shape 3, and a
   dispatch-level shape 2 — which is what D3's CI clause actually asks for.

ADR 0008 D2 lists six Ctrl chords, and the class-B gate that exists to prove
D2 live drove **none** of them: its `--input-chords` string is printables,
Left, Up and Return only. The chords were host-tested and nothing more. They
cannot be proven over synthesized USB — VZ ignores `modifierFlags` on a
synthesized keyDown, so a ctrl token arrives as the bare letter (three
failing synthesis routes are recorded in the hardware contract) — so phase 2
feeds the exact bytes a real Ctrl chord produces (0x01/0x05/0x0b/0x15/0x0c/
0x03, which is precisely what `input.zig`'s HID decode emits) over the serial
console, exercising the same `LineEditor` path from one byte earlier. Each
chord is proven by the command that ends up running, never by the keystroke.

The two-phase gate needed one runner change: `forwardScriptOnce` capped its
marker wait at 40 s, and phase 2's marker cannot appear until phase 1's ~24
synthesized keystrokes have elapsed at 3 s each. The bound now also extends
to the session `--timeout`, which is the honest ceiling — a marker can never
arrive after the VM is gone. It only ever widens the wait.

## Verified

- ✅ Positive control: the shape-walk test was run before the fixes and
  failed, naming `mbox`'s and then `beans`'s non-conformant lines; the
  transcript gate failed with exactly the intended diff before the fixture
  was regenerated.
- ✅ class A: `zig fmt --check` clean; `zig test kernel/src/monitor.zig`
  375/375; `zig test kernel/src/shell.zig` 416/416;
  `bash tools/verify-unit-tests.sh` all module suites pass;
  `zig build test-console` + `verify-transcript` byte-identical to the
  regenerated fixture; `zig build`, `zig build image`, `swift build`;
  `bash tools/verify-coordination.sh` ok.
- ✅ class B: `bash tools/verify-live-editing.sh` **PASS on VZ** with the new
  phase — `chords: ctrl-a=1 ctrl-e=1 ctrl-k=1 ctrl-u=1 ctrl-l=1 ctrl-c=1
  cancelled-never-ran=1`, alongside the unchanged phase-1 assertions
  (`armed=1 acb-x2=1 done=1 serial-ok=1 runner-flag=1`). The first run of
  this gate FAILED honestly (all six chords 0) because of the 40 s marker
  bound; the fix is above and the re-run is the PASS.
- ✅ class B regression: `bash tools/verify-live-win-hig.sh` PASS after these
  changes (the framebuffer console is on the same byte path).

## Open question for review (not decided here)

D3's text spells shape 3 with a typographic em dash (`— try 'help'`), but the
framebuffer text layer renders only 0x20–0x7e, so an em dash would draw as
blank cells on Road Pops. `main` deliberately emits ASCII `--` and documents
why; the unmerged branch emitted the literal em dash. The code keeps `--`;
the ADR text should probably be amended to say ASCII so the doc and the
renderer agree. Flagged rather than silently resolved.
