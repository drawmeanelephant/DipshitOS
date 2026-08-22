# Log — `agent/buffy/m18-t16-scripting`

### 2026-08-22 — claim 0469

Claimed (issue #419, M18 T16). Basic scripting mode: `sh <script>` reads a
plain-text file of shell commands and executes it line by line through the
normal `handle_line()` path (env expansion, aliases, builtins all apply).
Bounds: 64 lines × 256 chars, 16 KiB BSS staging. `#` comments, empty
lines skipped, no abort-on-error, `exit` stops early, scripts cannot call
scripts. `sh` is both a shell builtin (execution) and a registered monitor
command (help/usage/completion).

## 2026-08-22 — claim 0469: boot regression found + fixed

Class-B bring-up hit a **pre-existing boot hang on main**: every M18
kernel (T1–T15) stopped at the `aslr:` seam before the shell banner on
VZ; `438b57f` (pre-M18) booted. Bisected to `804fdc0` (M18 T1): its
`const scrollback_vtable` is the claim-0015/ADR-0005 bug class — const
function-pointer tables hold absolute addresses that are wrong at the
runtime load base, and the first write through the wrapped console
faults silently. Fixed by building the vtable at runtime into BSS
(`ensure_scrollback_vtable`), the repo's established pattern. After the
fix, main HEAD boots and the T16 walk passes.

## 2026-08-22 — claim 0469 done

`verify-live-scripting.sh` PASS 1/1 on real VZ: `write SCRIPT.TXT echo
t16-first-marker` on the ESP → `sh SCRIPT.TXT` outputs the marker;
`sh NESTED.TXT` → `sh: scripts cannot call scripts` and the inner script
never runs (marker-count asserted);`sh MISSING.TXT` → honest not-found; completion marker. Class-A green: 544/544 shell tests (8 new T16),
transcript byte-identical, build/image, BSS budget 9.85/11.0 MiB,
coordination. (Gate header initially hung: unescaped backticks around
`sh` in the banner echo ran a nested shell — fixed.)

## 2026-08-22 — claim 0469 follow-on: all five M18 class-B gates PASS on VZ

Ran the outstanding M18 live gates on real VZ, per request:
`verify-live-scrollback` (T1), `verify-live-selection` (T2),
`verify-live-search` (T3), `verify-live-history` (T4), `verify-live-color`
(T5) — all PASS 1/1. Evidence under `artifacts/live-{scrollback,selection,
search,history,color}-*` (gate/report/serial logs); per-claim evidence
sections added to the five claim files.

Bring-up findings (all observed on VZ, not inferred):
- The four keyboard-driven gates could never run as written: VZ's
  synthesized keyboard cannot deliver ESC/control bytes (`macKey` maps
  none), so `--input-string` aborted with "needs --display/--screenshot"
  and control chars have no keycode. Rewrote their phase 2 as a second
  serial script (`--script2`) with literal bytes — the verify-live-editing
  pattern — exercising the same shell code paths.
- The runner only honors `--script2`/`--script-expect` in script mode
  (requires `--script`; history boot 2 uses an empty script file), and it
  exits as soon as `--script-expect` matches (so the expected line must be
  the script's LAST line).
- **Kernel bug found:** `load_history()` restored HISTORY.TXT
  oldest-first (backward iteration put the file's first line at
  history[0]), contradicting the newest-first intent — the first Up arrow
  after reboot recalled the OLDEST command. Fixed (insert in file order)
  + host test + `esp.set_disk_ready_for_test` hook. 545/545 tests.
- Search-mode accepts must be `\r` (search_handle only accepts 0x0D).
- Color (T5) needed no changes and passed as written.

## 2026-08-22 — claim 5093: pageup/pagedown/escape keyboard chords (runner + guest)

Follow-up request: add the missing `macChord` tokens so future gates can
type real scroll keys through the keyboard instead of serial bytes. The
M18 gate bring-up had shipped with serial-injected CSI bytes because the
runner had no ESC/PageUp/PageDown tokens and the guest keymap refused
those usages. This change closes both halves:

- Runner (`host/vm-runner/Sources/VMRunner/main.swift` `macChord`): new
  tokens `pageup` (kVK 0x74, NSPageUpFunctionKey), `pagedown` (kVK 0x79,
  NSPageDownFunctionKey), `escape` (kVK 0x35, NSEscapeFunctionKey) —
  plain keys, no modifiers, so they translate like the existing
  up/down/left/right/home/end/delete chords (modifier chords remain
  blocked by the activation wall, unchanged).
- Guest (`kernel/src/input.zig` `hid_to_bytes`): usages 0x4b (PageUp →
  `ESC [ 5 ~`), 0x4e (PageDown → `ESC [ 6 ~`), 0x29 (Escape → lone ESC).
  The shell's scroll interceptor and the line editor already consumed
  those byte streams; this fills the decode gap. Host tests extended.
- Gate: `verify-live-scrollback.sh` phase 2 now types
  `pageup,pageup,pageup,pagedown,pagedown,pagedown,escape` then
  `echo scroll keys ok` via `--input-chords` (with `--input --display`),
  and a serial `input` report after the typed marker proves
  events=27 dropped=0 — every chord reached the guest keymap.
- Hardware contract: HID keyboard row updated to list the plain nav keys
  (incl. pageup/pagedown/escape) as translatable via synthesized chords.

## 2026-08-22 — claim 5093 follow-up: gate bring-up found 3 real T1/T2 shell bugs; fixed + all 5 gates green

The keyboard-chords scrollback gate FAILED on the first VZ run in a way
that exposed pre-existing shell defects (not runner or keymap issues —
the input report proved all 33 chord events decoded with dropped=0):

- The typed line arrived mangled: `unknown command '[5[6[6cho ...'` —
  the shell's scroll tracker consumed the `~` of each PageUp/PageDown
  sequence, leaving the line editor dangling mid-`ESC [ <param>`; the
  next ESC was swallowed and `[5`/`[6` fragments inserted into the line.
  The ORIGINAL serial gate had the same mangling but passed because its
  asserts grepped substrings of the mangled line.
- A real Enter (0x0D) after scrolling back to live hit the T2 selection
  branch (selecting stayed true at offset 0) and copied+discarded the
  line instead of submitting it; only serial `\n` had slipped past.
- The lone-ESC-in-selection cancel fired on the byte AFTER the ESC and
  consumed it — the keystroke following an ESC chord was lost.

Fixes (all in `kernel/src/shell.zig` + `kernel/src/lineedit.zig`):
1. `LineEditor.csi_reset()` — poll resets the editor's CSI state
   whenever the scroll tracker consumes a byte (both paste and main
   paths).
2. `scroll_handle(6)` clears selection when the offset reaches 0.
3. The lone-ESC cancel passes the following byte through instead of
   eating it.

Added 3 host tests; 548/548 shell tests. All five M18 live gates
re-passed on VZ with the fixes (selection/search/history/color unchanged
walks): scrollback PASS (keyboard walk, typed=1 report events=33
dropped=0), selection PASS, search PASS, history PASS, color PASS.
Claims 9867/7675 updated with the findings; hardware contract HID row
updated (claim 5093).

## 2026-08-22 — verify-live-selection.sh: PageUp/Up now typed through the keyboard

Follow-up to claim 5093: moved the T2 gate's scroll keys off serial and
onto the synthesized keyboard. Phase 2 is `--input-chords "pageup,up"`
(after the fill marker); phase 3 keeps ONLY the Ctrl chords on serial
(`--script2` with `--script2-delay 12` so the burst lands after the two
chords finish at ~9s — the chords are silent, so no guest marker exists
to gate on). The walk ends with `input`, whose report proves the keyboard
chords: `events=2 dropped=0 kb-usage=0x52 kb-byte=A`.

PASS 1/1 on real VZ; observed in the serial log: `copied` (Ctrl+C copy of
the keyboard-made selection), the pasted clipboard line submitting
(`unknown command 'line-16'` — the paste proof; the gate now greps the
`line-1x` shape instead of the old always-true `line-01` check, and it
is now part of the pass condition), and the events=2 input report. The
modifier wall (hardware contract) keeps Ctrl+C/Ctrl+V on serial — only
plain-key chords can be typed.

## 2026-08-22 — verify-live-search.sh: query + Enter-accept now typed through the keyboard

Follow-up to claim 5093: moved the T3 gate's query typing and accept off
serial. The walk now sends ONLY the Ctrl+R entry over serial (a modifier
chord — activation wall); the query `s,p,e,c,i,a,l` and the Return
accept are `--input-chords` (28 chords total incl. the marker echo, at
2.0s/event). Every query chord re-prints the search bar, so the
`(reverse-i-search)`special`: echo special-search-target-777` line in the
serial log is the honest proof that the keyboard-typed query matched the
right history line (replaces the old grep, which the phase-1 fill output
satisfied trivially).

**Kernel fix found:** the keyboard Return decodes to LF (0x0a), but
`search_handle` accepted Enter only as CR (0x0d) — a synthesized Return
in search mode was silently ignored. The line editor already treats CR
and LF alike; search now does too (+ host test). The first two gate runs
failed on a GATE typo, not delivery: my chords typed the marker with
spaces (`echo search live ok`) while the expect greps the hyphenated
string — the serial log showed the whole walk executed fine both times.
With the chords fixed to `-` tokens, PASS 1/1 on real VZ (search=1
match=1 done=1 runner-flag=1, rc=0). 549/549 shell tests, all class-A
green; claim 8879 updated.

## 2026-08-22 — verify-live-history.sh: post-reboot Up recall now a keyboard chord

Follow-up to claim 5093: boot 2's Up arrow is now a single
`--input-chords "up"` NSEvent (the ask: "a single keyboard 'up' chord");
the Enter that submits stays serial (the original walk's `\r`), and the
serial burst (--script2-delay 15, past the single chord) also runs
`input` — the report proves the chord decoded exactly once (`events=1
kb-usage=0x52 kb-byte=A`). The recall output only appears if the chord
landed (history is not printed at load). PASS 1/1 on real VZ; the boot-2
log shows recall echo, clean execution output, the events=1 report, then
the marker.

**False-pass caught:** the first two-chord version (`up,return`) PASSED
but dishonestly — the Return chord was lost in delivery (CHORD-SEQ
ok=true host-side, but the guest saw only the up; recall echo present,
no submit), and the +15s serial burst appended to the still-open recalled
line so the gate's substring greps matched the mangled output. The gate
now requires the events=1 input report, so a lost chord fails honestly.
Claim 3679 updated.

## 2026-08-22 — M18 class-B sweep: all five live gates PASS in one session

Ran the five M18 live gates back-to-back on real VZ: scrollback (T1),
selection (T2), search (T3), history (T4), color (T5) — all PASS 1/1.
Consolidated evidence: `artifacts/m18-sweep-2026-08-22.txt`; per-gate
evidence under `artifacts/live-{scrollback,selection,search,history,color}-*`
(gate logs + report files + serial logs).

**Evidence-recording bug found & fixed:** my gate rewrites declared a
`local REPORT=0` assertion flag that SHADOWED the global `REPORT` file
path — the per-boot detail lines were appended to stray files named `0`
or `1` (depending on whether the assertion set the flag) instead of the
report files. Search (no local `REPORT`) recorded correctly; scrollback,
selection, and history had the shadow. Renamed the flag to `INREPORT` in
all three, deleted the stray files, and re-ran the sweep so every report
file carries its per-boot line. Also caught a leftover stray `1` file
from the earlier failed-scrollback runs.
