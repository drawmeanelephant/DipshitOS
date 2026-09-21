package vi

// M71g (issue #1566): the EL0 kill seam — ADR 0007 slot 29 `sys_kill`.
//
// The kernel is the single source of truth for the contract
// (kernel/src/syscall.zig, ADR 0007 row 29, mirrored by
// user/src/lib/ui/abi.zig `kill_process` — Zig's TOP.BIN kill rides it):
//
//   - The call ARMS the target; the target exits with the reserved status
//     137 at its NEXT ring selection. The OS, not the caller, owns process
//     lifetime, so a successful Kill means "armed", never "gone" — the exit
//     line arrives on its own.
//   - 0 means armed; the raw negative ADR 0007 error otherwise: -EINVAL
//     (out-of-range / free / exited target, a non-process caller, or a
//     scheduler-owned refusal) and -EACCES (-7) when the caller's principal
//     may not kill the target (ADR 0024 D5, the cross-principal denial
//     live-trust-caps pins).
//
// Off the guest this degrades to -ENOSYS like every other vi call; the arm
// path stays unit-testable through the syscallHook seam (kill_test.go).
func Kill(pid uint64) int64 { return svc1(SlotKill, uintptr(pid)) }
