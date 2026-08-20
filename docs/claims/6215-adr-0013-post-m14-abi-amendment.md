# Claim: ADR 0013 (proposed) — post-M14 syscall + event-kind reservation

- **Owner:** buffy (`freebuff/can-you-review-issues-223-247-and-try-to-provide-h-f6c8d8a0-9349-4ada-9bca-1705150f0bde`)
- **Prompt / plan:** user request 2026-08-20 — "Draft the post-M14 ADR 0007 amendment that reserves syscall slots 47–54 and event kinds 10–16 in a single decision record, so issues #224/#236/#237/#238/#240/#241/#242/#246 can each cite it instead of each amending ADR 0007 separately."
- **Scope:** docs only — `docs/decisions/0013-post-m14-abi-amendment.md` (the proposed ADR; status: **proposed** until M14 closes and the first post-M14 claim lands). No ADR 0007 amendment, no syscall table change, no event-kind table change. ADR 0013 is a **reservation**, not an activation.
- **Depends on:** M14 S1 (clipboard, slots 38–39) + M14 S2 (app timers, slots 40–41) closing first; ADR 0007's `implemented_count` reaches 42 before any post-M14 claim cites ADR 0013.
- **Status:** ✅ done 2026-08-20 (as **proposed** ADR; the status flips to **accepted** when M14 closes and the first post-M14 claim cites it) — `docs/decisions/0013-post-m14-abi-amendment.md` exists (~18 KiB, ~290 lines), with D1 slot reservation (47–54), D2 event-kind reservation (10–17 with kind-12/13/16 collision resolutions called out by name), D3 BSS budgets + D3.1 observed measurement, D4 ABI contract under reservation, D5 slot-allocation table after M14 + post-M14, D6 event-kind table, D7 layering rule, D8 modifier matrix, and an Open-issues section for the implementing claims.

## Notes

**Why this ADR exists:** issues #224, #236, #237, #238, #240, #241, #242,
#246 each propose new kernel ABI surface — one syscall slot apiece (or
two in #238's case) and a handful of new event kinds. Without an upfront
reservation, every post-M14 claim would amend ADR 0007 individually and
re-litigate the collision table (event kind 12 has three competitors:
#228 R_UP, #236 SCROLL, #237's drag cascade). With ADR 0013, the
reservations land once and each implementing claim cites ADR 0013 by
number — the collision resolution is documented **once** in D2, called
out explicitly, and a future agent cannot re-litigate it without
amending ADR 0013.

**D1 — slot reservation (47–54):** eight slots reserved for the
post-M14 cards. **A reserved slot returns `-ENOSYS` (-4) until the
corresponding claim lands its row.** The signatures match the issue
bodies where unambiguous; the per-issue comment threads record where the
issue is loose.

| Slot | Name | Signature | Linked issue |
|:---:|:---|:---|:---|
| 47 | `sys_win_resize` | `resize(id, w, h) -> i64` | #224 |
| 48 | `sys_drag_start` | `drag_start(buf_ptr, buf_len) -> i64` | #237 |
| 49 | `sys_win_raise_front` | `raise_front(id) -> i64` | #238 |
| 50 | `sys_win_lower_back` | `lower_back(id) -> i64` | #238 |
| 51 | `sys_notify` | `notify(text_ptr, text_len, level) -> i64` | #240 |
| 52 | `sys_win_move_to_workspace` | `move_to_workspace(id, ws) -> i64` | #241 |
| 53 | `sys_win_set_unsaved` | `set_unsaved(id, flag) -> i64` | #242 |
| 54 | `sys_setrlimit` | `setrlimit(type, value) -> i64` | #246 |

**D2 — event-kind reservation (10–17), with collisions resolved:**

| Kind | Name | Source | arg0 contract |
|:---:|:---|:---|:---|
| 10 | `WIN_RESIZE` | #224 | `arg0 = new w`, `arg1 = new h` |
| 11 | `MOUSE_RIGHT_DOWN` | #228 | `arg0 = local x`, `arg1 = local y` |
| 12 | `MOUSE_SCROLL` | #236 | bits 0–13 magnitude, bit 14 horizontal, bit 15 sign |
| 13 | `MOUSE_RIGHT_UP` | #228 (moved from 12) | `arg0 = local x`, `arg1 = local y` |
| 14 | `DRAG_ENTER` | #237 | `arg0 = payload size`, `arg1 = source pid` |
| 15 | `DRAG_LEAVE` | #237 | `arg0 = 0`, `arg1 = source pid` |
| 16 | `DROP` | #237 | `arg0 = payload size`, `arg1 = source pid`, `arg2 = payload ptr` |
| 17 | `WIN_UNSAVED` | #242 (moved from 16) | `arg0 = 0/1/2` (save/don't save/cancel) |

**Resolutions called out explicitly (so future agents cannot re-litigate
without amending ADR 0013 D2):**

- Kind 12 = `MOUSE_SCROLL`, not `MOUSE_RIGHT_UP`. #228's original
  proposal of 11/12 is amended to 11/13.
- Kind 16 = `DROP`. #242's `WIN_UNSAVED` was originally proposed for
  kind 16 — moved to kind 17.
- Kinds 14–16 drag trio are kept contiguous (any future drag-variant
  kind goes at 18+).

**D3 — BSS budgets (per-issue estimates): 1,737 B (≈ 1.7 KiB).**

**D3.1 — Observed measurement, 2026-08-20:**

| Build | `.bss` size | Hex |
|---|---|---|
| Baseline (no stubs) | 6,119,552 B (5.84 MiB) | `0x5d6080` |
| With 7 stubs + 1 MiB canary | ~7,170,000 B (~6.84 MiB) | *(not re-measured)* |
| **Delta** | **~1,050,000 B (~1.002 MiB)** | *(not re-measured)* |

**LTO lesson (recorded as the rationale for D3.1's "honest measurement"
protocol):** each small stub (`var [N]u8 = [_]u8{0} ** N;`) was declared
zero-initialized; the keepalive function reads only `arr[0]`, which the
optimizer can prove returns `0` for every call. With no observable
side effect, the entire chain folds to a constant and the variables are
LTO-stripped despite `export var` and `export fn`. **The implementing
claims must declare their stubs in modules where live code touches the
bytes** (scheduler increments cpu_ticks on every tick; notify FIFO is
populated by `sys_notify` and drained by the compositor's idle loop;
etc.) — the 1,737 B estimate is then **observed**, not LTO-folded away.

The class-A BSS-budget gate (claim 6560) **enforces a 7.0 MiB ceiling**
(measured baseline 6,119,552 B + 1,220,480 B headroom). To raise the
ceiling, amend ADR 0013 D3.1 with the post-change measurement + a
justification, then bump `BSS_BUDGET_BYTES` in `tools/verify-bss-budget.sh`.

**D7 — compositor layering rule, locked once:**

```
wallpaper < taskbar < dock (#229) < tray (#226) < user windows
              (per-workspace #241, fade-alpha per #239)
              < modal dialog (#221 / #242) < drag_preview (#237)
              < notification (#240)
```

Five different cards (#224 resize, #225 overlay, #226 tray, #227 snap
preview, #229 dock, #239 fade) paint layered regions. This rule lives
in **one place** — D7. Future compositing changes cite D7 or amend it
once.

**D8 — modifier matrix, locked once:**

| Chord | Owner |
|---|---|
| `Alt` + Tab / Shift+Tab | #225 Alt+Tab cycling |
| `Alt` + two-key sequence | #245 compose (dead key) |
| `Ctrl+Shift+F` / `Ctrl+Shift+B` | #238 raise / lower |
| `Ctrl+F1` / `F2` / `F3` | #241 workspace switcher |
| `Shift` + wheel | #236 horizontal scroll |
| `Ctrl+F` / `Ctrl+H` | #231 NOTEPAD-private |

A future card adding a new chord amends ADR 0013 D8 first. The M7
keyboard decoder (claim 6050) consumes this table.

**What this ADR does NOT do:**

- It is not POSIX, libc, `errno`, or a compatibility ABI.
- It is not a uaccess change, fault-dispatcher change, scheduler-pool
  change, address-space change, or process-registry change.
- It is not a commit. Each post-M14 claim lands its **own** amendment
  to ADR 0007 (the executable contract), citing **this** ADR for the
  reservation. ADR 0007 remains the single source of truth for
  `implemented_count`.
- It does not unblock any pre-M14 claim. M14 must close first; this
  ADR's slots and kinds return `-ENOSYS` until then.

**Status transition:** status flips from `proposed` to `accepted` once
M14 closes and the first post-M14 claim lands. The implementing claims
amend ADR 0007 by adding their slot/kind row, citing ADR 0013 by number,
and updating the D5/D6 tables. The Open-issues section below names
the four decisions each implementing claim must make.

**Open issues for the implementing claims (recorded in the ADR for
future reference):**

1. Slot 53's `app_timeout` (default 5 ticks) is the per-app timer seam
   from M14 S2. The dialog widget (#221) is a sibling-issue that
   gates C10 of M15; the timeout is a soft cap and the kernel's
   `app_timeout` field may need to be per-app (configurable from
   SETTINGS) rather than global. Pick in the implementing claim.
2. Slot 54's CPU-tick accumulator rides on the scheduler's per-task
   CPU counter (M4 claim 5275 / 5795 have no such counter today).
   Adding one is a BSS-touch in `kernel/src/scheduler.zig`. The
   "argv-block extension" alternative (per #246's per-issue comment)
   lands limits in APPS.TXT manifest instead, removing the
   `sys_setrlimit` slot entirely. Pick in the implementing claim.
3. D7's `drag_preview` layer assumes `#237` includes a payload
   preview under the cursor. If the implementing claim lands a
   single-DROP highlight only, the `drag_preview` line drops out of
   D7.
4. D8's compose key row assumes `#245` uses two-key sequences. A
   three-key variant (e.g. dead-Alt + key + key) would need a second
   row here.

## Verified

- ✅ `docs/decisions/0013-post-m14-abi-amendment.md` exists (~18 KiB,
  ~290 lines).
- ✅ D1 reserves slots 47–54 with full signatures and per-issue links.
- ✅ D2 reserves event kinds 10–17 with kind-12/13/16 collision
  resolutions called out explicitly.
- ✅ D3 records per-issue BSS estimates (1,737 B) AND the D3.1
  observed measurement (baseline 6,119,552 B; delta ~1,050,000 B;
  canary-controlled; LTO caveat documented; exact with-stubs value
  marked as not re-measured).
- ✅ D7 layering rule and D8 modifier matrix present, with future cards
  named as owners.
- ✅ ADR status = **proposed**, with the proposed→accepted transition
  criterion spelled out.
- ✅ Open-issues section lists four decisions the implementing claims
  must make.
- ✅ docs only — no ADR 0007 amendment, no kernel change, no
  `implemented_count` bump. The reservations return `-ENOSYS` until a
  claim lands its row.
- ✅ Cross-references to claim 7656 (M15 plan) and claim 6560 (the
  BSS-budget gate that enforces the ceiling).
