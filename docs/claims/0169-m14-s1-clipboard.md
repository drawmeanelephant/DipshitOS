# Claim: Milestone 14 Card S1 — the bounded kernel clipboard (ADR 0007 slots 38–39)

- **Owner:** buffy (`freebuff/new-worktree-who-dis-84637f8c-617d-4718-b605-bebdba7963d9`)
- **Prompt / plan:** `docs/march-m14.md`
- **Scope:** Milestone 14, Card S1 (Issue #175: a clipboard / shared text service — `sys_clipboard_set`/`sys_clipboard_get`, NOTEPAD copy/cut/paste, terminal copy)
- **Depends on:** Milestone 13 (merged)
- **Status:** ✅ done 2026-08-18 — the bounded shared kernel clipboard (ADR 0007 slots 38–39) is live on VZ: the terminal `clip` command set/overwrite/get round-trips and the `syscalls` report shows `implemented=40` with slots 38/39 present; `tools/verify-live-clipboard.sh` PASS 1/1

## Notes

With text apps and a desktop launcher in place, the wishlist's shared-text
item becomes obvious: nothing can copy text between apps. This card adds ONE
bounded kernel clipboard buffer (pure BSS, zero heap) and exposes it to EL0
through two frozen ADR 0007 slots, following the slot-37 `sys_file_free`
precedent:

- `sys_clipboard_set(buf_ptr, len)` — slot 38. Copy `len` bytes (truncated
  honestly at the 512-byte buffer bound, the ipc/udp truncation pattern)
  from the caller's region through uaccess into the shared buffer. Returns
  the stored length; `EINVAL` for a non-process caller, `EFAULT` for a bad
  pointer.
- `sys_clipboard_get(buf_ptr, max)` — slot 39. Copy the current contents OUT
  through uaccess (peek → copy → no consume — a clipboard is a shared,
  non-destructive read). Returns the copied length; `EINVAL` for a
  non-process caller, `EFAULT` for a bad buffer; 0 when empty.

Layering: NEW `kernel/src/clipboard.zig` (a fixed `[512]u8` BSS buffer + a
length + a set counter, no allocation); `syscall.zig` registers slots 38/39
and bumps `implemented_count` 38 → 40 (S2 later adds 40/41 → 42). `ui.zig`
exposes typed wrappers. NOTEPAD grows Copy/Cut/Paste (Ctrl+C / Ctrl+X /
Ctrl+V over the existing Ctrl+A/E chord pattern). The EL1h half is the new
`clip` monitor command (`clip <text...>` sets it; `clip` prints it — the
terminal copy/paste proof; registry 44 → 45).

- Class-A tests at every layer (clipboard module, syscall dispatch + fault
  safety, monitor `clip` command, ui wrappers, notepad copy/cut/paste).
- Live gate `tools/verify-live-clipboard.sh`: drives NOTEPAD's copy/paste
  (or the `clip` command) on VZ and asserts the shared buffer round trip.
- ADR 0007 amendment documents slots 38–39.

## Result

- Class A green end to end (clipboard module 4/4; syscall dispatch + fault
  safety for slots 38/39; monitor `clip` command; ui wrappers; NOTEPAD
  copy/cut/paste chords) and the full `verify-portable` set passed.
- Class B `tools/verify-live-clipboard.sh` **PASS 1/1 on VZ** — `clip hello
  world` → `clip: stored 11 bytes`, `clip` → `clip: hello world`, `clip
  second` → `clip: stored 6 bytes`, `clip` → `clip: second`, and the
  `syscalls` report `implemented=40` with rows 38/39 present. The EL0
  dispatch/fault-safety path is proven at class A and is composition-proven
  with NOTEPAD copy/paste at card S3.
