// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The VirelaiOS syscall gateway (issue #1163, GOOS=virelai phase 0a).
//
// One `svc #0` per call: x8 = syscall number (ADR 0007, kernel/src/
// syscall.zig), x0-x5 = arguments, x0 = result (negative = the kernel's
// own errno). The guest counter (CNTPCT_EL0/CNTFRQ_EL0) is EL0-readable
// (the kernel arms CNTKCTL_EL1.EL0VCTEN/EL0PCTEN), so time never SVCs.

#include "go_asm.h"
#include "textflag.h"

// ADR 0007 slot numbers.
#define VIR_SYS_WRITE     1
#define VIR_SYS_YIELD     2
#define VIR_SYS_EXIT      3
#define VIR_SYS_MMAP      63
#define VIR_SYS_TIME      66
#define VIR_SYS_GETRANDOM 72

#define VIR_MMAP_PROT_RW  3
#define VIR_MAP_ANON      0x20

// func virWrite1(fd uintptr, p unsafe.Pointer, n int32) int32 — one
// sys_write (kernel cap 256 B/call; the Go side chunks). Virelai has ONE
// console and no fd table, so both runtime output descriptors (1 = stdout,
// 2 = stderr/fatal) alias to the kernel's slot-1 console write — the fd
// argument is accepted and ignored.
TEXT runtime·virWrite1(SB),NOSPLIT|NOFRAME,$0-28
	MOVD	$1, R0
	MOVD	p+8(FP), R1
	MOVW	n+16(FP), R2
	MOVD	$VIR_SYS_WRITE, R8
	SVC
	MOVW	R0, ret+24(FP)
	RET

// func virYield() — sys_yield (slot 2): a scheduler point, not a sleep.
TEXT runtime·virYield(SB),NOSPLIT|NOFRAME,$0-0
	MOVD	$VIR_SYS_YIELD, R8
	SVC
	RET

// func virExit(code int32) — sys_exit (slot 3), noreturn.
TEXT runtime·virExit(SB),NOSPLIT|NOFRAME,$0-4
	MOVW	code+0(FP), R0
	MOVD	$VIR_SYS_EXIT, R8
	SVC
	RET

// func virMmap(addr unsafe.Pointer, n uintptr) int — sys_mmap (slot 63)
// anonymous, read/write, demand-backed. x0 is the page-aligned address
// hint (the sbrk layer always passes the current mapped end, keeping the
// break contiguous). Returns x0: the mapped base (>= 0) or negative errno.
TEXT runtime·virMmap(SB),NOSPLIT|NOFRAME,$0-24
	MOVD	addr+0(FP), R0
	MOVD	n+8(FP), R1
	MOVD	$VIR_MMAP_PROT_RW, R2
	MOVD	$VIR_MAP_ANON, R3
	MOVD	$VIR_SYS_MMAP, R8
	SVC
	MOVD	R0, ret+16(FP)
	RET

// func virTime() int64 — sys_time (slot 66): the boot wall-clock epoch in
// unix seconds (ENOSYS without a firmware epoch; walltime tolerates it).
TEXT runtime·virTime(SB),NOSPLIT|NOFRAME,$0-8
	MOVD	$VIR_SYS_TIME, R8
	SVC
	MOVD	R0, ret+0(FP)
	RET

// func virGetrandom(p *byte, n int) int — sys_getrandom (slot 72): CSPRNG
// bytes for the runtime hash/PRNG seed. Returns x0 (count or negative).
TEXT runtime·virGetrandom(SB),NOSPLIT|NOFRAME,$0-24
	MOVD	p+0(FP), R0
	MOVD	n+8(FP), R1
	MOVD	$VIR_SYS_GETRANDOM, R8
	SVC
	MOVD	R0, ret+16(FP)
	RET

// func virCntFreq() uint64 — CNTFRQ_EL0, the guest counter frequency in
// Hz (read-only; Virtualization.framework picks it).
TEXT runtime·virCntFreq(SB),NOSPLIT|NOFRAME,$0-8
	MRS	CNTFRQ_EL0, R0
	MOVD	R0, ret+0(FP)
	RET

// func nanotime1() int64 — monotonic nanoseconds from the guest counter:
//   ns = (ticks * monoMul) >> 44
// with monoMul = floor(2^44 * 1e9 / cntfrq) fixed up at boot (osinit).
// UMULH gives the 128-bit product's high word; the split shift (high<<20
// | low>>44) reassembles the >>44 quotient exactly. Go asm operand order
// is source-first, DESTINATION-LAST (MUL Rn, Rm, Rd). NOSPLIT|NOFRAME:
// this is on the runtime's nosplit call chain.
TEXT runtime·nanotime1(SB),NOSPLIT|NOFRAME,$0-8
	MRS	CNTPCT_EL0, R0
	MOVD	runtime·monoMul(SB), R1
	MUL	R0, R1, R3
	UMULH	R0, R1, R2
	LSR	$44, R3, R3
	LSL	$20, R2, R2
	ADD	R2, R3, R2
	MOVD	R2, ret+0(FP)
	RET

// ADR 0027 D3 (phase 0b): the thread seam — slot 73 sys_thread, slot 74
// sys_futex. One `svc #0` per call: x8 = slot, x0-x5 = args, x0 = result
// (negative = the kernel's errno; the ADR 0007 amendment adds EAGAIN -11
// and ETIMEDOUT -12 for the futex).
//
// sys_thread(op, entry, stack_hi, arg, tls): op 0 create / op 1 exit.
// sys_futex(op, uaddr, val, timeout_ns):   op 0 wait / op 1 wake(n).

#define VIR_SYS_THREAD     73
#define VIR_SYS_FUTEX      74

// func virThreadCreate(entry, stackHi, arg unsafe.Pointer) int — slot 73
// op 0. Returns the new kernel tid (>= 0) or a negative errno.
TEXT runtime·virThreadCreate(SB),NOSPLIT|NOFRAME,$0-24
	MOVD	entry+0(FP), R1
	MOVD	stackHi+8(FP), R2
	MOVD	arg+16(FP), R3
	MOVD	$0, R0            // op 0 = create
	MOVD	$0, R4            // tls: reserved 0 (pure-Go arm64 keeps g in R28)
	MOVD	$VIR_SYS_THREAD, R8
	SVC
	MOVD	R0, ret+24(FP)
	RET

// func virThreadExit() — slot 73 op 1, noreturn: thread-only exit (the
// process dies when its LAST task exits; sys_exit stays process-exit).
TEXT runtime·virThreadExit(SB),NOSPLIT|NOFRAME,$0-0
	MOVD	$1, R0            // op 1 = exit
	MOVD	$VIR_SYS_THREAD, R8
	SVC
	JMP	0(PC)             // not reached

// func virFutexWait(uaddr unsafe.Pointer, val uint32, timeoutNs int64) int
// — slot 74 op 0. The kernel verifies *uaddr == val (4-byte LE) under the
// caller's uaccess window, parks the task, and returns 0 on a real wake,
// -EAGAIN on a mismatched word, -ETIMEDOUT on deadline expiry
// (timeoutNs == 0 waits forever).
TEXT runtime·virFutexWait(SB),NOSPLIT|NOFRAME,$0-24
	MOVD	uaddr+0(FP), R1
	MOVW	val+8(FP), R2
	MOVD	timeoutNs+16(FP), R3
	MOVD	$0, R0            // op 0 = wait
	MOVD	$VIR_SYS_FUTEX, R8
	SVC
	MOVD	R0, ret+24(FP)
	RET

// func virFutexWake(uaddr unsafe.Pointer, n uint32) int — slot 74 op 1.
// Wakes up to n waiters of the caller's process keyed (pid, uaddr);
// returns the number woken.
TEXT runtime·virFutexWake(SB),NOSPLIT|NOFRAME,$0-16
	MOVD	uaddr+0(FP), R1
	MOVW	n+8(FP), R2
	MOVD	$1, R0            // op 1 = wake
	MOVD	$VIR_SYS_FUTEX, R8
	SVC
	MOVD	R0, ret+16(FP)
	RET

// runtime·virThreadTrampoline — the entry newosproc passes to slot 73
// op 0. The kernel's child frame starts here with x0 = arg (the new m)
// and SP_EL0 = stack_hi (mp.g0.stack.hi). Pure-Go arm64 keeps g in R28:
// load g = mp.g0, then tail-jump mstart, which runs mstart0/mstart1 on
// this g0 stack exactly like every other GOOS's newosproc child. mstart1
// records the caller's SP (this g0 stack) via save(getcallersp()).
TEXT runtime·virThreadTrampoline(SB),NOSPLIT|NOFRAME,$0-0
	MOVD	m_g0(R0), g
	B	runtime·mstart(SB)
