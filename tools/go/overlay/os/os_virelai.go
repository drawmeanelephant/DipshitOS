// The rest of os's per-GOOS surface for GOOS=virelai: the pieces a platform
// provides when it has no /proc, no waitid and no pipe fds. Each one is the
// honest answer rather than a stand-in for a mechanism that exists.
package os

import (
	"errors"
	"syscall"
)

// executable has no slot to read its own path from: there is no /proc, and
// the kernel tells a program its identity through argv[0] (the monitor's own
// argv convention), which os cannot see from inside the package. Saying so
// beats inventing a path — the caller that wants its own name has it in
// os.Args[0] already.
func executable() (string, error) {
	return "", errors.New("Executable not implemented for virelai; use os.Args[0]")
}

// blockUntilWaitable: this kernel has no waitid-shaped call. The guest's
// process table is watched through sys_procs and reaped by the kernel, so
// there is nothing for a caller to block on here. (Same shape as
// wait_unimp.go's answer for aix/darwin/js/wasip1.)
func (p *Process) blockUntilWaitable() (bool, error) {
	return false, nil
}

// hostname: there is no uname and no /etc/hostname in this guest, and the
// name a reader would want (the monitor's "virelai-kernel") is the monitor's
// version answer, not a kernel slot. Failing is the honest report.
func hostname() (string, error) {
	return "", errors.New("hostname not implemented for virelai")
}

// Pipe: a pipe at EL0 is not a pair of descriptors. The kernel's pipe
// machinery (GOSH's pipelines) is a slot-level stream between tasks, not
// something a guest can hand to os.File, and the port refuses to fabricate a
// descriptor pair for it.
func Pipe() (r *File, w *File, err error) {
	return nil, nil, NewSyscallError("pipe", syscall.ENOSYS)
}
