# Claim: milestone six card G3 — Road Pops, the boot terminal goes graphical

- **Owner:** buffy (`agent/buffy/m6-roadpops`)
- **Prompt / plan:** the G3 follow-on of `docs/m6-text-prompt.md` (the
  roadmap's Road Pops bullet) — the boot terminal re-targeted to the
  screen.
- **Scope:** milestone six, card G3 — re-target the M1.5 console (line
  editor, tokenizer, command registry, shell idle loop) to render into a
  framebuffer region instead of the serial pipe; the machine still boots
  to a terminal — now on the screen. Serial stays as the evidence/log
  channel (the transcript gates keep passing).
- **Depends on:** milestone six cards G1 (claim 6053 — virtio-gpu) + G2
  (claim 3194 — framebuffer text) on merged main. No M5-close gate; the
  default VM must stay byte-identical (the tee degrades to serial-only
  without the gpu device).
- **Status:** ✅ **done 2026-08-12** — `agent/buffy/m6-roadpops`

## What landed

- **`kernel/src/road_pops.zig`** (~330 lines): a TEE console. `State`
  holds the underlying serial `console.Console` (the shared seam — every
  byte still reaches serial FIRST, so the transcript gates keep passing
  byte-identical) plus an injectable framebuffer `Target`
  (put_bytes/present/clear, armed only when the gpu is ready). `write`
  → serial + G2's text layer (cheap ring writes) + dirty;
  `present_if_dirty` → ONE full-frame present per output batch; the
  FIRST present emits `text: boot banner presented` on the base console
  (the G2 evidence, now honest: the boot banner — the shell's own — IS
  presented at that moment); `readByte` delegates (input stays on serial
  until G4); no target → serial-only (byte-identical default VM).
  RAM-built vtable (the claim-0015 relocation lesson). 18 host tests
  (tee order, batching, degradation, boot evidence once, flush, readByte
  delegation, clear, report).
- **`kernel/src/main.zig`:** the G2 one-shot boot paint is REPLACED by
  the tee: after `gpu_setup`, Road Pops is armed over the m15 console
  with the framebuffer-text target; the monitor's console becomes the
  tee, so the shell's OWN banner + prompt + every reply render on the
  screen (Road Pops). Without a gpu, the tee degrades to serial-only.
- **`kernel/src/shell.zig`:** the idle loop calls `road_pops.drain()`
  (the card-3d shell-idle-drain pattern, next to `net_rx_drain`) — one
  present per dirty output batch.
- **Monitor:** `roadpops` command (registry 36→37) reporting
  armed/dirty/presents; shell help + the byte-identical transcript
  fixture updated (the row sits between `repeat` and `screen`).
- **Class A green:** fmt; the full unit suite (35 modules — road_pops's
  18 tests + a monitor `roadpops` command test); byte-identical
  transcript; build/image/inspect; swift build; context; coordination;
  mmu-debt.
- **Class B gate `tools/verify-live-roadpops.sh` — PASS 1/1 on VZ:** the
  scripted boot runs `echo ROADPOPS` + `uname` + `roadpops`; the gate
  asserts the shared-seam serial evidence (`roadpops: armed
  target=fbtext`, `text: boot banner presented` — the G2 evidence
  retained via the tee's first present, `roadpops: armed=1 … presents>=1`,
  the banner + the echo/uname replies on serial) AND decodes the
  captured PNG: the boot-banner region (fg=0.255 over bg=0.745) AND the
  TERMINAL region below it (fg=0.124 — the echoed commands + replies
  rendered live) — a working terminal on screen, not a one-shot splash;
  the region below all background. Registered in `tools/sweep-vz.sh`
  (the aggregate is now 37 gates) + `justfile`.
- **Aggregate:** the full **37-gate `verify-vz` sweep re-ran green
  37/37** (`artifacts/m6-roadpops-vz-sweep.log`) — the default VM stayed
  byte-identical (the tee's serial-only degradation).

## Claim-time observations (recorded honestly)

- **Claim-0015 redux, observed live:** a `road_pops.Target` struct
  literal with all-constant fields (ctx + `&fn` entries) was folded by
  the compiler into `.rodata` — whose `&fn` entries hold LINK-TIME
  absolute addresses. The tee's first write dispatched through the
  tainted pointer and faulted at the link-time address of
  `rp_text_put_bytes` (`esr=0x02000000 ec=0x00 elr=0x14260` — the
  link-time image offset, far from the runtime base; identified by
  disassembling the stripped kernel and matching 0x14260 to the
  two-arg wrapper `mov x0,x1; mov x1,x2; b puts`). Fix: build the Target
  in RAM at runtime (like `ensure_vtable`) so every `&fn` resolves
  PC-relatively. The disassembly also confirmed the compiler had hoisted
  the argument to a rodata pointer (`adrp x1, 0x1a000` at the arm call
  site).
- **G1/G2 gates updated honestly for the Road Pops reality:** the
  terminal's drain-presents render over a raw `screen fill`, so G1's
  pixel phase now asserts the NON-BLANK terminal frame (the fill is
  proven guest-side: `fill=…ff00 transfer=ok flush=ok` + `peek p1=0xff`)
  and its `cmds=` counter is session-dynamic (heartbeat/worker reports
  the tee renders add TRANSFER+FLUSH pairs) — the health contract
  `errors=0 timeouts=0` is the stable assert. The `text` report's
  cur/lines are now session-dynamic too (the echoed session + the
  report's own output land in the ring — the report reflects its own
  progress mid-print); G2's gate asserts the stable parts (region, cell,
  fg/bg). Both gates re-passed, and the 37-gate aggregate is green.
- Live-pixel bound (the G1/G2 precedent): byte-exact text is the class A
  mock's domain; the live assertion is "text is visible in the expected
  regions with the expected color family" (color-managed +
  retina-scaled). A step-16 whole-frame sample aliases against the 8px
  glyph grid (measured fg=0 at step 16 vs fg=0.156 at step 2) — the
  gates sample the text regions at fine steps.

## Bounds

No input device (G4 — keystrokes still arrive via serial), no window
manager (G5), no syscall numbering (ADR 0007 frozen), no heap or
unbounded tables, no default-config or framebuffer/format changes, no new
devices, no unobserved `[observed]` claims.
