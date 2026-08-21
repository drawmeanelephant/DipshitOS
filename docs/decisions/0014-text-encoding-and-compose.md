# ADR 0014: Text encoding in the input event ABI and compose-key sequences

Status: **accepted** · Date: 2026-08-21 · Milestone: Arc5 (system polish)

## Context

The input system (milestone seven, ADR 0009) decodes HID keyboard boot reports into ASCII
bytes. `KEY_DOWN` events carry the decoded ASCII byte in `arg1` (0x20–0x7e for printable,
0x00–0x1f for control). Arrows and function keys use 3-byte escape sequences (ESC + letter).
This works for the English-centric app set but cannot represent accented characters (é, ü, ñ,
ç), currency symbols (€, £), or any non-Latin script.

Arc5 issue #245 requires compose-key sequences (Alt+e+vowel → acute accent, etc.) for
system polish. The compose table maps ~30 two-key sequences to Unicode codepoints that
have no ASCII representation. This forces an architecture decision: how do non-ASCII
characters flow through the 16-byte event wire format?

---

## Decision: Unicode codepoints in KEY_DOWN arg1

**KEY_DOWN and KEY_UP events carry Unicode codepoints (U+0000–U+FFFF BMP) in `arg1`,
replacing the current ASCII-byte contract.** The `kind`, `flags`, `seq`, and `arg0` fields
are unchanged. Backward compatibility is preserved by convention: existing apps that treat
`arg1` as ASCII already work for codepoints U+0020–U+007e (the ASCII range). New apps
that understand Unicode can handle the full BMP.

### D1. arg1 encoding change

| Field | Before (ADR 0009) | After (ADR 0014) |
|-------|--------------------|--------------------|
| `arg1` for KEY_DOWN/KEY_UP | ASCII byte (0x00–0x7f) | Unicode codepoint (U+0000–U+FFFF) |

- Codepoints 0x00–0x7f are identical to ASCII — **no breaking change** for existing apps.
- Codepoints 0x80–0xffff are new — apps that ignored arg1 (graphics-only) are unaffected;
  apps that printed arg1 as a char will now print the correct Unicode character on hosts
  that support it (the serial console is ASCII, but the framebuffer text layer can render
  Unicode via a future glyph extension).
- The `arg0` field still carries the HID usage ID for apps that need raw key identification.

### D2. Compose state machine (kernel input layer)

The compose state machine lives in `kernel/src/input.zig`, between HID decode and event
dispatch. It intercepts Alt+key combinations before they reach the event queue:

```
State: IDLE → (Alt held) → COMPOSE期待 → (key) → lookup → KEY_DOWN with Unicode codepoint
```

1. **IDLE**: normal processing. Alt alone does not generate a KEY_DOWN.
2. **COMPOSE期待 (waiting)**: Alt is held. The next non-modifier key starts a compose
   sequence. If the key is not a valid first key of any compose pair, the Alt+key is
   released as a normal KEY_DOWN (backward compatible).
3. **Lookup**: the two-key sequence (first_key, second_key) is looked up in a bounded
   compile-time table. On match, a single KEY_DOWN event with the Unicode codepoint is
   dispatched. On miss, both keys are dispatched as normal KEY_DOWN events.

The state machine is bounded: at most one pending key (no multi-byte buffering), no
allocation, no dynamic registration. The compose table is a `comptime` array of
`[2]u8 → u21` pairs.

### D3. Compose table (~30 pairs)

Groups:
- **Alt + e + vowel** → acute: é (U+00e9), á (U+00e1), í (U+00ed), ó (U+00f3), ú (U+00fa)
- **Alt + u + vowel** → umlaut: ä (U+00e4), ö (U+00f6), ü (U+00fc), ë (U+00eb), ï (U+00ef)
- **Alt + ` + vowel** → grave: è (U+00e8), à (U+00e0), ì (U+00ec), ò (U+00f2), ù (U+00f9)
- **Alt + n + n** → tilde: ñ (U+00f1)
- **Alt + c** → cedilla: ç (U+00e7)
- **Alt + , + c** → cedilla alternative: ç (U+00e7) — if comma is preferred over 'c' alone

Total: ~27 pairs. The table is compile-time constant, fits in BSS, no allocation.

### D4. No new syscall or event kind

The compose translation happens entirely inside the kernel's input layer (before
`events.push`). Apps receive a standard `KEY_DOWN` event with a Unicode codepoint in
`arg1`. No new syscall, no new event kind, no ABI amendment to ADR 0007.

### D5. `compose` monitor command

A new `compose` monitor command lists all available compose sequences and their output
codepoints. Registered in the monitor command registry. Pure diagnostic — no state
mutation.

---

## Consequences

### Positive
- Existing ASCII apps continue to work unchanged (codepoints 0x00–0x7f are ASCII).
- No new syscall slots consumed — the compose table is internal to the input layer.
- The 16-byte event wire format is unchanged — only the semantic meaning of arg1 broadens.
- The compose table is bounded (~30 pairs), compile-time constant, no allocation.

### Negative
- Apps that treat arg1 as a raw byte (e.g., `char c = (char)arg1`) will now receive
  Unicode codepoints > 127 for accented characters. On the serial console (ASCII-only),
  these will render as `?` or garbage. This is acceptable: the serial console is the
  evidence channel, not the user-facing display. The framebuffer text layer (G2) can be
  extended to render Unicode in a future milestone.
- The `arg0` HID usage ID becomes the only way to identify the physical key when arg1
  is a composed character. Apps that need raw key identification already use arg0.

### Risks
- **Low**: The change is backward-compatible for the ASCII range. The only risk is apps
  that do `(char)arg1` and expect only 0x00–0x7f — these will see new values but won't
  crash (they're printing or comparing, not indexing arrays).

---

## Rejected alternatives

### Alternative A: Separate COMPOSE event kind (kind=16)
Add a new event kind `COMPOSE` with the Unicode codepoint in arg0. Apps would need to
handle both KEY_DOWN and COMPOSE events. **Rejected**: doubles the event surface for
apps, requires updating every event loop, and the 16-byte wire format already has room
for a Unicode codepoint in arg1.

### Alternative B: Multi-event sequences for codepoints > 255
Deliver high codepoints as multiple KEY_DOWN events (e.g., ESC + codepoint bytes).
**Rejected**: complex, fragile, and the event wire format supports a full u32 in arg1
which can hold the entire BMP.

### Alternative C: Keep ASCII, translate at the app layer
Leave arg1 as ASCII and have each app implement its own compose logic. **Rejected**:
duplicates logic across apps, no consistent user experience, and the kernel already
owns the input decode path.

---

## References

- ADR 0009: Application events (event wire format, KEY_DOWN arg1 encoding)
- ADR 0008: Human interface guidelines (input handling conventions)
- Arc5 issue #245: Input method — compose sequences + text encoding decision
- `kernel/src/input.zig`: HID decode, keymap, event dispatch
- `kernel/src/events.zig`: Event struct, kind constants
