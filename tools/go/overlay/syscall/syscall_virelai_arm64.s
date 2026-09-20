// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The generic GOOS=virelai syscall entry (issue #1525, M70c-S1P).
//
// One `svc #0` per call: x8 = the ADR 0007 slot, x0-x5 = arguments, x0 =
// result (negative = the kernel's own errno). The runtime has its own
// per-slot gateways (runtime/sys_virelai_arm64.s) for the paths that must
// not allocate or split (console write, mmap, futex, thread); this one is
// the `syscall` package's general entry, where the Go side owns the
// chunking and the errno mapping.
//
// ABI0 (stack) is deliberate: the package declares the function without a
// body, so the compiler emits the register-ABI wrapper and this frame is
// the ABI0 one — the same shape the runtime's gateways use.

#include "textflag.h"

// func virginSvc(n, a1, a2, a3, a4, a5 uintptr) (r0, r1 int64)
TEXT ·virginSvc(SB),NOSPLIT|NOFRAME,$0-64
	MOVD	n+0(FP), R8
	MOVD	a1+8(FP), R0
	MOVD	a2+16(FP), R1
	MOVD	a3+24(FP), R2
	MOVD	a4+32(FP), R3
	MOVD	a5+40(FP), R4
	SVC
	MOVD	R0, r0+48(FP)
	MOVD	R1, r1+56(FP)
	RET
