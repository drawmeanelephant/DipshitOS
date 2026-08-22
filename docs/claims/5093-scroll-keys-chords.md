# Claim: VMRunner pageup/pagedown/escape keyboard chords + guest HID decode

- **Owner:** buffy (`agent/buffy/m18-t16-scripting`)
- **Prompt / plan:** follow-up to the M18 class-B gate bring-up — "Add
  pageup/pagedown (and ESC) chord mappings to VMRunner's macKey/macChord
  tables so future gates can type real scroll keys through the keyboard
  instead of serial bytes"
- **Scope:** the runner's `macChord` table gains `pageup` (kVK 0x74 /
  NSPageUpFunctionKey), `pagedown` (kVK 0x79 / NSPageDownFunctionKey) and
  `escape` (kVK 0x35 / NSEscapeFunctionKey) tokens; the guest
  `input.zig` `hid_to_bytes` gains usages 0x4b (PageUp → `ESC [ 5 ~`),
  0x4e (PageDown → `ESC [ 6 ~`) and 0x29 (Escape → lone `ESC`); the
  scrollback live gate types its scroll keys through the keyboard
  (`--input-chords`) instead of serial bytes; hardware contract updated
- **Depends on:** M18 T1–T5 live gates + the T1 boot-regression fix in the
  working tree (const vtable → BSS, claim 0469's find); the runner's
  `--input-chords` seam (claim 1809) and `--input --display` flags
- **Status:** ✅ done 2026-08-22

## Notes

Why: the M18 gates were brought up with serial-injected CSI bytes because
`macChord` had no ESC/PageUp/PageDown tokens and the guest keymap refused
the usages. Both halves of the chain are now covered so future gates can
type real scroll keys as synthesized key events.

Guest facts (already true, verified while bringing up the T1 gate): the
shell's scroll interceptor (`scroll_csi_track`) consumes `ESC [ 5 ~` /
`ESC [ 6 ~`; the line editor swallows unhandled CSI and treats a lone ESC
as a non-byte (`lineedit: a lone ESC does not eat the next keystroke`);
the app-events route already translates 0x4b/0x4e to MOUSE_SCROLL. The
missing half was `hid_to_bytes` (console route) refusing 0x4b/0x4e/0x29.

Hardware boundary (unchanged): **modifier** chords still never reach the
HID report (activation wall, hardware contract); ESC/PageUp/PageDown are
plain keys, so they translate like the existing up/down/left/right/
home/end/delete chords.

### Shell bugs found & fixed during gate bring-up (T1/T2 — NOT new code)

The keyboard walk exposed three real pre-existing shell defects that the
original serial gate had masked (its `\n` submissions and substring
greps never hit them; observed on VZ: the typed line arrived as
`[5[6[6cho …` and a real Enter discarded the line):

1. **Dangling editor CSI state** — the shell's tracker consumed the `~`
   of a scroll sequence, leaving the editor mid-`ESC [ <param>`; the
   next ESC was swallowed and `[5`/`[6` fragments inserted into the
   line. Fixed: `Shell.poll` calls the new `LineEditor.csi_reset()`
   whenever the tracker consumes a byte (both paste and main paths).
2. **Scroll-to-live kept selecting** — `scroll_handle(6)` left
   `selecting=true` at offset 0, so a real Enter (0x0D) copied+
   discarded the line (only serial `\n` slipped past the intercept).
   Fixed: selection clears when the offset reaches 0.
3. **Lone-ESC-in-selection ate the next keystroke** — the cancel fired
   on the byte after ESC and consumed it (the chord after ESC lost its
   first char). Fixed: the byte passes through to the editor.

All five M18 gates re-passed with the fixes in (selection/search/
history/color unchanged walks). 3 new host tests cover each fix.

### Verification

- Host (class A): `hid_to_bytes` unit tests for 0x4b/0x4e/0x29; 3 new
  shell tests (clean typing after scroll keys; pagedown-to-live clears
  selection so a real Enter submits; ESC-in-selection doesn't eat the
  next keystroke). 548/548 shell tests, all monitor modules, build +
  image, coordination — green.
- Class B: `tools/verify-live-scrollback.sh` updated — phase 2 types
  `pageup ×3, pagedown ×3, escape` then `echo scroll keys ok` and
  `input` via `--input-chords`; the shell's own input report proves all
  33 chord events reached the guest keymap with dropped=0 (the keyboard
  walk replaced the serial-bytes phase). **PASS 1/1** on real VZ;
  evidence `artifacts/live-scrollback-*`. The other four M18 live gates
  re-passed unchanged.
