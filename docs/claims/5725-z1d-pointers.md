# Claim: z1d-pointers

- **Owner:** antigravity (`agent/antigravity/z1d-pointers`)
- **Prompt / plan:** `docs/line-of-sight.md` (issue #753)
- **Scope:** Milestone 20 Lane 2 (Self-hosting Z1d: Pointers)
- **Touches:** user/src/zc.zig, user/src/lib/zc.zig, tools/verify-live-zc.sh, tests/zc-corpus/z1d-pointers.z, docs/claims/5725-z1d-pointers.md, docs/logs/agent-antigravity-z1d-pointers.md
- **Depends on:** 5487
- **Heartbeat:** 2026-09-02
- **Status:** ✅ done

## Notes

Implement Z1d pointers: address-of, dereference, pointer-typed parameters.

- Parse pointer types `*T`, `*const T`, `[*]T`, `[*]const T` in declarations and function parameter lists.
- Support `&x` (address-of local variables, struct members, and arrays) in `parsePrimary`.
- Support `x.*` (dereference load) in `parsePrimary`.
- Support `x.* = expr` (dereference store) in `compileStatement`.
- Support pointer parameter passing by reference (`swap(&a, &b)`).
- Support pointer indexing (`buf[i]`).
- Host unit tests in `user/src/zc.zig`.
- New corpus fixture `tests/zc-corpus/z1d-pointers.z` and `verify-live-zc.sh` live gate assertion.
