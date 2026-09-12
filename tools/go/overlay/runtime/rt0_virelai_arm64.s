// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// GOOS=virelai entry (issue #1163 phase 0a; argv wired in phase 0b B2).
//
// The kernel's exec entry contract (card 3e) passes R0 = argc and R1 = the
// argv BLOCK VA — eight 32-byte NUL-terminated string slots, NOT a SysV
// char* array. rt0_go wants R0 = argc, R1 = argv (pointer array). This stub
// converts: it reserves argc*8 bytes below SP and fills argv[i] = block +
// i*32 (each slot is already a NUL-terminated string in place). SP stays
// the g0 stack top for rt0_go's stack-bounds setup; the array lives below
// it and is read-only input from here on.

#include "textflag.h"

TEXT _rt0_arm64_virelai(SB),NOSPLIT|NOFRAME,$0-0
	CMP	$0, R0
	BNE	have_args
	MOVD	$0, R0
	MOVD	$0, R1
	JMP	runtime·rt0_go(SB)

have_args:
	MOVD	R0, R2         // argc
	MOVD	R1, R3         // argv block VA
	LSL	$3, R2, R4
	SUB	R4, RSP, RSP   // reserve argc*8 bytes below SP
	MOVD	RSP, R4        // array base
	MOVD	$0, R5         // i
build:
	CMP	R2, R5
	BHS	done
	LSL	$5, R5, R6     // i*32: slot stride
	ADD	R3, R6, R6     // &slot[i]
	MOVD	R6, (R4)(R5<<3)
	ADD	$1, R5, R5
	B	build
done:
	MOVD	R2, R0         // argc
	MOVD	R4, R1         // argv
	JMP	runtime·rt0_go(SB)
