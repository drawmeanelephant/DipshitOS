# ADR 0030: The language split (Zig owns the kernel, Go owns EL0)

- Status: ACCEPTED
- Date: 2026-09-15
- Issue: #1293 (this document), umbrella #1292
- Related: ADR 0001 (Zig as guest language — narrowed here), ADR 0007
  (syscall ABI; kernel changes still ride amendments of that file only),
  ADR 0015 (userland WM seat / slot 65), ADR 0020 (terminal seam),
  ADR 0021 (userland shell; the interactive shell moves to Go later, the
  kernel monitor stays), ADR 0026 (GOOS=virelai), ADR 0028 (HTML — already
  a Go consumer in M54), ADR 0029 (TLS stays a Zig helper)

> Product split, not a vibe: **VZ is the hypervisor. Zig is the guest
> kernel. Go is EL0.** This ADR is docs-only. It carries the M56–M60 card
> split; there is no separate scoping doc. Boot default does not move
> until M59.

## Context

M54 proved a Go EL0 program can own a raw ADR 0007 window (`GOWIN.ELF`)
and that an independent Go renderer (`WEB.ELF` over `user/go/webrender`)
can paint in-guest. The GOOS=virelai runtime (ADR 0026 / 0027) is the
substrate. What is still hostile is **Zig userland**: `tabwm.zig`,
`lib/ui`, every `.BIN`. New desktop work there is a second product in the
wrong language.

Zig userland cannot become a library Go calls. There is no cgo and no
FFI. `lib/tls`, `lib/html`, and `LIBUI.SO` are dead to Go. The shared
contract is the one that already exists: ADR 0007 syscalls, WM_RPC over
slots 5/6, and on-disk file formats. Zig EL0 binaries become things you
`exec`, then you delete them.

ADR 0001 D3 said Zig is the guest implementation language. That remains
true for the kernel. It is no longer true for the desktop.

## Decision

**D1. Zig is the guest kernel, forever.** Zig owns `boot/`, `kernel/`,
virtio, GIC, the scheduler, the syscall table, the Swift runner, and the
serial monitor (the ADR 0021 boot/recovery console). `WASM.BIN` / `ZC.BIN`
may remain Zig tools. No new Zig GUI. Kernel changes in this arc ride
ADR 0007 amendments only; this file adds no slots.

**D2. Go is the EL0 product.** Go owns the WM, chrome, apps, and
eventually the interactive shell. Programs are statically linked
`GOOS=virelai` ELFs. The SDK is `user/go/vi`; it is never `LIBUI.SO`.
New UI is written once, in Go.

**D3. The contract is ABI and formats, not libraries.** A Go program
speaks ADR 0007 and WM_RPC the same way a Zig program does. It does not
link Zig objects, wrap `lib/ui`, or import a C ABI. Leftover Zig apps
keep working because they already speak that contract, not because Go
embeds them.

**D4. Forbidden moves** (every card in this arc; the load-bearing list):

- No Go rewrite of the kernel.
- No dual widget toolkits: small Go widgets actually needed (text,
  button, list) live under `user/go/tabapp` or a tiny `user/go/ui`.
  Never a `LIBUI` clone, never a second competing toolkit.
- No new `user/src/*.zig` GUI apps.
- No porting crypto "because pivot": TLS stays a Zig *helper*
  (`TLS.BIN` / `FETCHS.BIN` over TCP, ADR 0029) and SSH stays `SSH.BIN`
  until their own cards exist.
- No `settings set wm` / boot-default flip before M59. AGENTS.md's
  "do not change the boot default" rule yields only on that card. **#1298 is
  that card, and it has landed**: the compiled `wm` default is `gotabwm`, so
  a boot with no persisted setting seats the Go desktop; `settings set wm
  tabwm` keeps the Zig seat, and `settings set wm none` is the explicit
  shim-only VM the pre-M59 fleet assumed.
- No claiming a milestone parent (`#1296`, `#1295`, `#1294`) — those are
  indexes. Claim the leaf.

**D5. Seat discovery stays userland.** `is_wm_name` / `wm_peers` in
`user/src/lib/ui/abi.zig` currently accept `WND.BIN` or `TABWM.BIN`
(M42 SX3). `GOTABWM.ELF` must eventually match that list so leftover Zig
clients find the Go seat. That is a name-table change, not a kernel ABI
change; it lands with M57/M59, not with this file. Slot 65 remains
one-seat (`REGISTER` → `EACCES` if taken).

**D6. The first code of the pivot is a Go tab inside Zig TABWM, not a
Go WM.** If `user/go/tabapp` cannot speak WM_RPC as a *client*, a Go WM
is a second monolith. M56 finishes `vi` and lands one full-viewport Go
app in the existing seat. M57 is an opt-in second seat. M59 is the only
card allowed to make it the default.

**D7. This unblocks desktop work in Go. It does not absorb unrelated
debt.** The pivot neither blocks on nor fixes the #1252 nudge / VZ abort
(#1287), TLS consumers beyond the helper already on main, or DNS. Those
stay their own cards.

## Card split (M56–M60)

Parents `#1296` / `#1295` / `#1294` are indexes. Claim the leaf with
`just claim-card <n>`. No card declares `docs/status.md` in `Touches`
(status rows merge at landing). New gates are declarative specs under
`tools/gate/specs/`; extend an existing spec when it already covers the
change.

| # | Card | Claim | What "done" means |
|---|------|-------|-------------------|
| **M55** | This ADR | #1293 | This file reads ACCEPTED. No code. |
| **M56** | Finish the Go SDK | index #1296 | A Go tab speaks WM_RPC inside Zig TABWM on VZ; `vi` is enough to be a client. Kernel untouched. |
| M56a | `vi`: IPC 5/6 + `sys_procs` peer discovery | #1311 | Host tests for the WM_RPC wire / discovery. |
| M56b | `vi`: tab-client WM_RPC kinds + event dispatch | #1316 | Host tests. Depends on M56a. |
| M56c | `vi`: addr-hinted mmap (the GOWIN `addr=0` hole) | #1314 | Host tests; guest path is not `addr=0`. |
| M56d | `user/go/tabapp` + one Go app full-viewport in Zig TABWM | #1315 | **First commit of the pivot.** The milestone's only VZ card (`go-tabapp`): open / declare-fullscreen / resize / close, no `[EXC]`. Filled rect + title is enough — no widgets yet. |
| M56e | Go widgets: text, button, list | #1319 | Host-tested. Depends on M56d. Not a LIBUI clone. |
| **M57** | `GOTABWM.ELF` as a second seat | index #1295 | Unmodified Zig binaries run on the Go seat on VZ. Opt-in; default stays TABWM. One spec (`go-wm-seat`) grows. No Zig TABWM changes. |
| M57a | GOTABWM registers slot 65, composites a blank desktop | #1313 | Starts `go-wm-seat`: register, compose, clean unregister; default boot still TABWM. |
| M57b | GOTABWM manages its own Go windows | #1317 | Extends `go-wm-seat` (rect / chrome / focus / close). |
| M57c | GOTABWM hosts leftover Zig CALC/NOTEPAD | #1318 | Completes `go-wm-seat`. Parity on the exercised path only. |
| **M58** | Move the apps you touch | index #1294 | One app per card, full-viewport via `tabapp` in **Zig TABWM**. Does **not** wait on M57. Browser is already Go (M54). Leave CALC until it is in the way. Leave Zig `FILE.BIN` / `EDIT.BIN` / `TERM.BIN` until M60. |
| M58a | Go file manager | #1305 | `go-files` on VZ: open, list a known share file, close. |
| M58b | Go editor | #1306 | `go-edit` on VZ: open fixture, dirty, save, close. Usable buffer + save, not EDIT's feature list. |
| M58c | Go terminal front-end (ADR 0020) | #1307 | `go-term` on VZ: attach, a typed line / shell marker, close. No new tty syscall. |
| M58d | Go fetch over the Zig TLS helper | #1308 | HTTPS via the Zig helper; never a cleartext GET. No Go crypto. DNS is not this card. |
| **M59** | Explicit default flip | #1298 | The **only** card allowed to move the boot default. `settings set wm gotabwm` persists; Zig TABWM remains the fallback. Touches include `kernel/src/shell.zig` (that is where the WM boot default lives), not only a settings panel. Gate: flip → reboot → Go WM hosting a leftover Zig app. Depends on M57 (second seat proven) and at least one leftover Zig app hosted under it. **Landed:** `wm` is a schema-v2 settings key whose compiled default is `gotabwm`; the shell-idle autostart resolves the seat through it (`gotabwm` → `GOTABWM.ELF`, `tabwm` → `TABWM.BIN`, `none` → shim), `tools/session.sh` stages the Go seat and lets the default apply, and `go-wm-default` proves the default boot on VZ (boot 01: no `wm` key → the Go seat hosts CALC; boot 02: the persisted `wm=tabwm` → the Zig seat). A boot whose share carries no seat binary says so and stays shim-only instead of faking a desktop. |
| **M60** | Starve Zig EL0 | #1297 | Mini-umbrella: record the no-new-Zig-apps policy; each leftover deletion is its own claim against this card. No flag day. TLS/SSH stay Zig helpers until their own Go cards. |

Superseded drafts (closed, do not claim): original M56/M57 leaves
#1300–#1304; both-seats M58 drafts #1309, #1310, #1312, #1320.

## Consequences

- Agents write desktop and apps in Go. Zig userland stops growing.
- The kernel stays the small hostile core. A Go WM is still an EL0
  process on slot 65; it does not move policy back into EL1.
- Zig leftover apps keep working across the seat change because WM_RPC
  is the contract, provided `is_wm_name` learns `GOTABWM.ELF` (D5).
- Two seats exist from M57 onward, and since M59 the Go one is the
  default. The compiled default idles the pre-M59 way only when it is
  asked to (`settings set wm none`) or when the seat binary is not on the
  share — in which case the boot reports the miss and stays shim-only.
- `LIBUI.SO` / `user/src/lib/ui` become the toolkit of the dying Zig
  desktop, not a thing to port.

## Not decided here

- Syscall rows, `tabapp` shape, GOTABWM internals, widget metrics — M56
  and later.
- Whether the interactive shell (`SH.BIN`) flips in this arc or after
  M60. D2 says "eventually"; no card above moves it.
- Go ports of TLS or SSH.
- Deleting Zig TABWM (M60, after the default has already flipped).
