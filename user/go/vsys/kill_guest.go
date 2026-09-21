//go:build virelai

package vsys

// Process termination over sys_kill (slot 29, ADR 0007).
//
// kill(target_pid) arms the target process's executor for termination from
// EL0: the ring converts the target's NEXT selection into the existing exit
// path with the reserved status 137 (the OS, not the program, owns process
// lifetime). Returns 0 once armed; EINVAL for an out-of-range / free /
// exited target or a scheduler-owned refusal (the shell, idle); EACCES when
// the target belongs to a different principal and the caller lacks
// cap_proc_admin (same-principal kills, including self-kill, need no cap).
const SlotKill uintptr = 29

// Kill arms pid for termination (slot 29) and returns the raw kernel result:
// 0 armed, negative errno otherwise.
func Kill(pid uint64) int64 {
	return syscallFn(SlotKill, uintptr(pid), 0, 0, 0)
}
