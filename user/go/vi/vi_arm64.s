//go:build virelai

// VirelaiOS guest syscall gateway for Go programs (ADR 0007).
//
// One `svc #0` per call: x8 = syscall slot, x0-x5 = arguments, x0 = result
// (negative = the kernel's own errno). This mirrors the exact idiom the
// GOOS=virelai runtime overlay uses (tools/go/overlay/runtime/
// sys_virelai_arm64.s), so the app layer and the runtime speak one seam.

#include "textflag.h"

// func syscall0(num uintptr) int64
TEXT ·syscall0(SB),NOSPLIT|NOFRAME,$0-16
	MOVD	num+0(FP), R8
	SVC
	MOVD	R0, ret+8(FP)
	RET

// func syscall1(num uintptr, a0 uintptr) int64
TEXT ·syscall1(SB),NOSPLIT|NOFRAME,$0-24
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	SVC
	MOVD	R0, ret+16(FP)
	RET

// func syscall2(num uintptr, a0, a1 uintptr) int64
TEXT ·syscall2(SB),NOSPLIT|NOFRAME,$0-32
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	SVC
	MOVD	R0, ret+24(FP)
	RET

// func syscall3(num uintptr, a0, a1, a2 uintptr) int64
TEXT ·syscall3(SB),NOSPLIT|NOFRAME,$0-40
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	MOVD	a2+24(FP), R2
	SVC
	MOVD	R0, ret+32(FP)
	RET

// func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64
TEXT ·syscall4(SB),NOSPLIT|NOFRAME,$0-48
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	MOVD	a2+24(FP), R2
	MOVD	a3+32(FP), R3
	SVC
	MOVD	R0, ret+40(FP)
	RET

// func syscall6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64
TEXT ·syscall6(SB),NOSPLIT|NOFRAME,$0-64
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	MOVD	a2+24(FP), R2
	MOVD	a3+32(FP), R3
	MOVD	a4+40(FP), R4
	MOVD	a5+48(FP), R5
	SVC
	MOVD	R0, ret+56(FP)
	RET
