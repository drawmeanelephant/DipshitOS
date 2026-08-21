# Log — agent/buffy/m6-roadpops

Branch: `agent/buffy/m6-roadpops` · Slug: `roadpops` · Claim: [1574](claims/1574-roadpops.md)
Prompt: the G3 follow-on of [m6-text-prompt](m6-text-prompt.md) · Started from merged main
`0fcd96b` (docs: milestone-five cards N7/N8 planning-first prompt).

## 2026-08-12 — claim

- **Claim:** branch `agent/buffy/m6-roadpops`; claim ID 1574 via
  `tools/status/claim-id.sh`; claim doc + this log +
  `refresh-indexes.sh`.
- **Prompt:** the milestone-six G3 Road Pops follow-on (the boot terminal
  re-targeted to the framebuffer; the roadmap bullet + the
  m6-text-prompt follow-on).
- **Design:** `kernel/src/road_pops.zig` — a tee console (serial shared
  seam + an injectable framebuffer target, armed only when the gpu is
  ready; drain-present at the shell idle loop); the G2 direct boot paint
  replaced by the tee rendering the shell's own banner; the `roadpops`
  monitor command (registry 36→37); class A + class B gates; docs
  reconciliation.
- **Status:** 🔄 — implementation in progress.

## 2026-08-12 — done

- **Class A green:** fmt; the full unit suite (35 modules — road_pops's
  18 tee tests + a monitor `roadpops` command test); byte-identical
  transcript (the `roadpops` help row sits between `repeat` and
  `screen`); build/image/inspect; swift build; context; coordination;
  mmu-debt.
- **Class B `tools/verify-live-roadpops.sh` PASS 1/1 on VZ:** serial
  evidence (`roadpops: armed target=fbtext`, `text: boot banner
  presented` — the G2 evidence retained via the tee's first present,
  `roadpops: armed=1 … presents>=1`, the banner + echo/uname replies on
  serial — the shared seam) + the DECODED capture: the boot-banner
  region (fg=0.255) AND the terminal region below it (fg=0.124 — the
  echoed commands + replies rendered live) — a working terminal on
  screen; region below all background. Evidence `artifacts/live-roadpops-*`,
  `artifacts/gpu-screen-*s`.
- **Claim-time fix (claim-0015 redux, observed live):** the
  `road_pops.Target` struct literal was folded into `.rodata` with
  link-time `&fn` addresses — the tee's first write faulted at the
  link-time `rp_text_put_bytes` (`esr=0x02000000 elr=0x14260`; matched
  by disassembling the stripped kernel); the Target is built in RAM now.
- **G1/G2 gates updated honestly:** the terminal's drain-presents render
  over a raw fill (G1's pixel phase now asserts the non-blank terminal
  frame; the fill is proven guest-side; `cmds=` is session-dynamic); the
  `text` report's cur/lines are session-dynamic (its own output feeds
  the ring) — G2 asserts the stable region/cell/fg/bg. Both re-passed.
- **The 37-gate `verify-vz` aggregate re-ran green 37/37**
  (`artifacts/m6-roadpops-vz-sweep.log`) — the default VM byte-identical.
- **Docs:** march-m6 G3 → ✅; roadmap G3 bullet + Graphics row; status
  milestone-six row + next-step item; gate-inventory (37-gate aggregate
  + `live-roadpops` row + the G1/G2 rows' honest notes); README +
  architecture (the road_pops.zig tee surface); AGENTS.md (G1–G3 done);
  claim doc flipped; indexes refreshed.
- **Status:** ✅ done.
