# Claim: z1b-arrays

- **Owner:** t3code (`t3code/b5bdb1b1`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #751)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1b: Arrays)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1b-arrays.z, docs/claims/9685-z1b-arrays.md, docs/logs/t3code-b5bdb1b1.md
- **Depends on:** 8708
- **Heartbeat:** 2026-09-01
- **Status:** ✅ t3code/b5bdb1b1

## Notes

Implement Z1b fixed-size arrays in BSS/stack with scaled-index ldr/str addressing:

- Add `[` `]` tokens and tokenizer handling.
- Extend `user/src/zc.zig` locals to track array base offset, length, elem_size with frame_size; allocate arrays in stack frame (sub sp 512).
- Array type parsing `[N]u8` / `[N]u64` in var declarations; support `var buf: [8]u8 = undefined;` init.
- Indexed load `arr[i]` in expressions (scaled lsl + add + ldr/ldrb) and indexed store `arr[i] = expr` in statements.
- New builtin `zc.print_array(buf)` (host `lib/zc.zig` anytype wrapper) for byte-exact array output.
- Add corpus `tests/zc-corpus/z1b-arrays.z` and extend `verify-live-zc.sh` to assert live array fill + write byte-exact (ABCDEFGH) and host compile-check.
