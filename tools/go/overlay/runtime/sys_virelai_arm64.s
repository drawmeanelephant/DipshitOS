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
#define VIR_SYS_GETRANDOM 74

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

// func virGetrandom(p *byte, n int) int — sys_getrandom (slot 74): CSPRNG
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
