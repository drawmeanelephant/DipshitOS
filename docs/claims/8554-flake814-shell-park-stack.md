# Claim: #814 — the shell RX path moves to a dedicated 64 KiB park stack

- **Owner:** buffy (`freebuff/https-github-com-drawmeanelephant-dipshitos-issues-281dbccf-094a-4d25-8cc5-156e51271c8c`)
- **Prompt / plan:** issue #814 (filed from claim 3997's Z2a flake evidence)
- **Scope:** kernel flake fix — the #803/#810 crash family, boot-stack discipline (ADR 0004 D5)
- **Touches:** kernel/src/shell.zig docs/claims/8554-flake814-shell-park-stack.md docs/logs/agent-buffy-flake814-shell-park-stack.md
- **Depends on:** —
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Measured (disassembly, 2026-09-02): the pre-fix `shell.boot_and_park` merged
frame (setup + loop inlined) was 0x4750 (18,256 B) on the 16 KiB handoff
boot stack (ADR 0004 D5) — its bottom and every parked IRQ frame landed in
the loader-data pocket below `handoff.stack_base`, corrupting state
(issue #814's elr 0x8d44/0x8f54 corrupted-callee-saved class; raw_sp
0x7da72310 = 0xcf0 BELOW the stack base, claim 3997). The measured
SETUP-ONLY path was already ~0x4010 (Shell.init's by-value return staging
inlined at sp+0x3c40 + rc_buf + restore/dispatch locals) — the ENTIRE 16
KiB stack before kernel_main's live frame — so NO part of the RX path may
run on the boot stack.

Final implementation (the issue's direction, "one task, one stack"):
`boot_and_park` is now a ~0x50-frame wrapper that, in the RX-wired case,
SP-switches FIRST via one self-contained inline-asm block (save boot
SP/LR in callee-saved x19/x20, load x0 = monitor / x1 = park_stack top,
`mov sp, x1`, `bl` the AAPCS64 body, restore tail) and runs the WHOLE
park path — init, history/env/window restore, .virelairc AND the loop —
as `park_body` on a dedicated 64 KiB static `park_stack` (BSS). 64 KiB,
not the 32 KiB task standard: LLVM keeps the deepest command-dispatch
frames (~0x4000 each) as separate functions that NEST under park_body's
merged frame, and IRQ frames land on the task stack too (~40 KiB worst
measured depth; +64 KiB against ~510 KiB BSS headroom). The no-RX path
(banner + prompt, ~0x100 of locals) still runs on the boot stack. Host
tests stay pure Zig (the comptime aarch64 branch is elided; `park_body`
is called directly).

Intermediate designs that were tried and rejected (disassembly-evidenced):
a naked `park_entry` trampoline + fn-pointer call got tail-merged by the
optimizer into the .virelairc exit path (`b.ls` jumped INTO the trampoline
body with leftover registers — `mov sp, x2` executed with rc-remaining,
sp = garbage → silent death). The inline-asm form with all-register
operands cannot be outlined into a wrong-ABI shape.

Proof: class A green (zig fmt, unit tests, verify-bss-budget — 478,120 B
headroom, verify-coordination, byte-exact shell transcript gate);
class B `verify-live-zc.sh` PASS **3/3 boots on VZ** (BOOTS=1 then
BOOTS=2 — every phase incl. the plain `exec MAIN.ELF` → exit 72 and the
`rx-zc-ok` echo, no fatal), decisive against the ~50% flake. Residual
finding: intermediate builds AND unmodified HEAD also hit a separate
post-ZC register-corruption crash/freeze in the claim-9094 audit drain
(x23/x26 = GIC values; elr offset 0x37b6c) — the #810 family, tracked
separately and outside this issue's scope.
