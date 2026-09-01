# Claim: z1c-structs

- **Owner:** t3code (`t3code/z1c-structs`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #752)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1c: Structs)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1c-structs.z, docs/claims/5487-z1c-structs.md, docs/logs/t3code-z1c-structs.md
- **Depends on:** 9685
- **Heartbeat:** 2026-09-01
- **Status:** 🔄 t3code/z1c-structs

## Notes

Implement Z1c structs: aggregate types with field offsets.

- Add `struct` keyword tokenizer.
- Struct table (`StructDef`/`Field`) with packed offsets, size calculation, `lookupStruct`.
- Parse `const Name = struct { a: u64, b: u8, ... }` in Pass1, allocate size.
- Extend `LocalVar` with `is_struct`/`struct_idx` + `frame_size` handling for `var s: MyStruct`.
- Member load `s.field` in `parsePrimary` (add+ldrb/ldr) and member store `s.field = expr` in `compileStatement`.
- Builtin `zc.print_struct(s)` host (`anytype` → `write(1, bytes)`) and guest (`add x1,x19,off` + `svc 1`).
- Corpus `tests/zc-corpus/z1c-structs.z` and `verify-live-zc.sh` struct fill + byte-exact + host compile-check.
