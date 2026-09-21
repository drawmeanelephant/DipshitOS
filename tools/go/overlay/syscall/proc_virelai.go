// Process, exec, signal and socket surface for GOOS=virelai.
//
// This file exists because `os`, `internal/poll` and `internal/syscall/execenv`
// name these symbols unconditionally, not because the guest can do what they
// say. Each non-trivial body below is the honest answer for this kernel:
//
//   - There is no fork/exec *syscall* at EL0. Programs are exec'd by the
//     monitor's seat (ADR 0021) and by `sh`'s own slot use (user/go), not by
//     a std caller, so StartProcess/Wait4 report ENOSYS instead of pretending
//     to spawn. `os/exec` therefore compiles and fails loudly, which is the
//     right shape for a slice whose card is "go build fmt succeeds".
//   - There is no signal delivery: the kernel has no signal slot, SIGKILL of
//     a task is the monitor's business, and Kill is ENOSYS.
//   - There are no sockets (no net slots yet), so Accept is ENOSYS. The
//     Sockaddr interface exists only so internal/poll's accept hook has a
//     type to name.
//   - There is no timestamp-writing slot, so the timestamps a share file
//     reports are the host's (see internal/syscall/unix's Utimensat, which
//     stands in for the stock linkname-based one).
//   - CloseOnExec is a no-op for the same reason O_CLOEXEC is: nothing at EL0
//     inherits a descriptor table across exec.
package syscall

import "sync"

// ForkLock is taken by callers that already had a race to lose (internal/poll's
// dupCloseOnExecOld, syscall's own exec path). Nothing here forks, so it is
// never contended — it exists so the stock code that locks it compiles and so
// a future exec slot has the lock already in place.
var ForkLock sync.RWMutex

// CloseOnExec marks a descriptor close-on-exec. No-op: see the file header.
func CloseOnExec(fd int) {}

// Sockaddr is the address interface net-shaped code passes around.
type Sockaddr interface {
	sockaddr()
}

// Accept has no kernel slot to call. internal/poll's accept() wrapper only
// reaches it for socket descriptors, which cannot exist here.
func Accept(fd int) (nfd int, sa Sockaddr, err error) {
	return -1, nil, ENOSYS
}

// Credential and SysProcAttr mirror the POSIX structs so callers that build
// one compile and can read back what they set. Nothing consumes them: there is
// no spawn path to apply them to.
type Credential struct {
	Uid    uint32
	Gid    uint32
	Groups []uint32
}

type SysProcAttr struct {
	Chroot     string
	Credential *Credential
	Ptrace     bool
	Setsid     bool
	Setpgid    bool
	Setctty    bool
	Noctty     bool
	Ctty       int
	Foreground bool
	Pgid       int
}

// ProcAttr is the pre-spawn description os/exec fills in.
type ProcAttr struct {
	Dir   string
	Env   []string
	Files []uintptr
	Sys   *SysProcAttr
}

// StartProcess is ENOSYS: see the file header. It is NOT a silent success —
// a caller that thinks it spawned something must be told otherwise.
func StartProcess(argv0 string, argv []string, attr *ProcAttr) (pid int, handle uintptr, err error) {
	return 0, 0, ENOSYS
}

// Exec has no slot either, and the nearest thing is NOT a stand-in for it.
//
// `syscall.Exec` is execve: replace THIS process's image and never return on
// success. The kernel does have an exec seam — sys_exec, slot 28 (ADR 0007)
// — but its documented job is to load a program into a FRESH process slot and
// spawn it at EL0, i.e. it is a spawn, not a replace. Forwarding to it would
// produce a child while the caller kept running its old image, which is the
// opposite of what the caller asked for; that is a lie with a plausible-
// looking pid attached, not an implementation. Returning ENOSYS tells the
// truth: this GOOS has no way to become another program.
//
// The one caller reached in practice is cmd/link's execArchive, which shells
// out to an external archiver only for cgo/external linking. Nothing on the
// virelai path takes that branch, so this is a link-time symbol that the
// in-guest compile never calls — the same shape as StartProcess above.
//
// (Stock's version lives in syscall/exec_unix.go, tagged `unix`, which this
// GOOS does not select.)
func Exec(argv0 string, argv []string, envv []string) (err error) {
	return ENOSYS
}

// Wait4 has no slot: the guest's process table is read through sys_procs
// (slot 22) and reaped by the kernel, not by a wait4-shaped call.
func Wait4(pid int, wstatus *WaitStatus, options int, rusage *Rusage) (wpid int, err error) {
	return 0, ENOSYS
}

// Kill has no slot: a process is ended by exiting (sys_exit) or by the
// monitor's WIN_CLOSE path, never by another guest's signal.
func Kill(pid int, sig Signal) error { return ENOSYS }

// Signal numbers, typed as Signal because std stores them in Signal-typed
// variables (os/exec_posix.go's interrupt/kill globals). The kernel delivers
// none of these: the constants exist so a caller can name the signal it would
// send and a log line can say which one was refused.
const (
	SI_USER   Signal = 0x0
	SIGHUP    Signal = 0x1
	SIGINT    Signal = 0x2
	SIGQUIT   Signal = 0x3
	SIGILL    Signal = 0x4
	SIGTRAP   Signal = 0x5
	SIGABRT   Signal = 0x6
	SIGBUS    Signal = 0x7
	SIGFPE    Signal = 0x8
	SIGKILL   Signal = 0x9
	SIGUSR1   Signal = 0xa
	SIGSEGV   Signal = 0xb
	SIGUSR2   Signal = 0xc
	SIGPIPE   Signal = 0xd
	SIGALRM   Signal = 0xe
	SIGTERM   Signal = 0xf
	SIGSTKFLT Signal = 0x10
	SIGCHLD   Signal = 0x11
	SIGCONT   Signal = 0x12
	SIGSTOP   Signal = 0x13
	SIGTSTP   Signal = 0x14
	SIGTTIN   Signal = 0x15
	SIGTTOU   Signal = 0x16
	SIGURG    Signal = 0x17
	SIGXCPU   Signal = 0x18
	SIGXFSZ   Signal = 0x19
	SIGVTALRM Signal = 0x1a
	SIGPROF   Signal = 0x1b
	SIGWINCH  Signal = 0x1c
	SIGIO     Signal = 0x1d
	SIGPWR    Signal = 0x1e
	SIGSYS    Signal = 0x1f
)

// The three descriptors every program starts with. They are not file-channel
// handles: the console is the kernel's own stream (see Write in
// fs_virelai.go), which is why they are defined here rather than opened.
const (
	Stdin  = 0
	Stdout = 1
	Stderr = 2
)

// ImplementsGetwd: Getwd answers from the port's own record of the working
// directory (the kernel has a chdir slot but no getcwd), so os does not have
// to synthesise a path by walking "..".
const ImplementsGetwd = true

// ESRCH: "no such process". Nothing here produces it (there is no signal or
// wait path), but os/exec_unix.go compares against it.
const ESRCH Errno = 40
