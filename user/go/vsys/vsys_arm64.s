// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// The GOOS=virelai SVC gateway for package vsys (ADR 0007 / ADR 0026 D2).
// One svc #0: x8 = slot, x0-x3 = args, x0 = result (negative = kernel errno).

#include "textflag.h"

// func syscall4(num uintptr, a0, a1, a2, a3 uintptr) int64
TEXT ·syscall4(SB),NOSPLIT|NOFRAME,$0-40
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	MOVD	a2+24(FP), R2
	MOVD	a3+32(FP), R3
	SVC
	MOVD	R0, ret+40(FP)
	RET
