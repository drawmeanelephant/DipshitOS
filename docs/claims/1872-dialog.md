# Claim: Dialog / modal window helper for ui.zig (GH #221)

- **Owner:** Muse Spark (`agent/buffy/arc1-progressbar`)
- **Prompt / plan:** `docs/m17-desktop-completeness.md` Arc1 + GH #221
- **Scope:** Arc1 pure `user/src/lib/ui.zig` Dialog — 300×150 centered child, exclusive focus, parent dim overlay, message 1–3 lines 8×8, optional TextInput, OK/Cancel Buttons, result enum OK/Cancel + text, show() is event-loop pattern via sys_wait_event (no blocking syscall), no new ABI/event, host tests + BSS budget, FILE.BIN delete-confirm nice-to-have
- **Depends on:** M17 done, #218 ScrollView + #219 Checkbox/Toggle done, #220 ProgressBar done (same branch)
- **Status:** ✅ done 2026-08-21 — `user/src/lib/ui.zig` Dialog + 3 host tests, `zig test` 29/29, `verify-bss-budget` 9788088/11534336, `verify-coordination` PASS

## Notes

Implements Dialog per GH #221 grooming: child 300×150 centered over parent rect (clamped if parent <300×150), exclusive modal focus, parent dim overlay via `draw_dim_overlay(parent_win_id)` (theme_border fill), message 1–3 lines 8×8 split by '\n'/wrap35, optional TextInput (Rect 10,60, w-20,20), OK/Cancel `Button`s at (w-140, h-30,60,20) and (w-70, h-30), result `enum{none,ok,cancel}`, `show()` resets open+result+input+button states, `dismiss()`, `is_open()/needs_dim()/get_result()`, `handle_event` routes KEY_DOWN Enter(0x28)→ok Escape(0x29)→cancel + TextInput typing, MOUSE_* forwarded to Buttons (hover/pressed/click) then TextInput focus, modal consume (click inside/outside while open). No kernel block — app polls via `sys_wait_event` loop per grooming. Host tests: centered geometry (400×300→50,75 + small parent clamp), OK/Cancel via Button click sequence (DOWN+UP) + keyboard + dismiss, dim flag, TextInput focus/type/backspace + draw_dim_overlay/draw no-panic. Zero heap, pure BSS value type, FILE.BIN delete-confirm nice-to-have deferred. Verified: `zig test` 29/29, `zig fmt` PASS, `zig build` PASS, `verify-bss-budget` 9788088/11534336.
