// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// GOOS=virelai entry (issue #1163 phase 0a; argv wired in phase 0b B2;
// envp wired in issue #1226).
//
// The kernel's exec entry contract (card 3e) passes R0 = argc and R1 = the
// argv BLOCK VA — eight 256-byte NUL-terminated string slots, NOT a SysV
// char* array. The envp block (issue #1226) sits immediately after argv:
// sixteen 128-byte KEY=VALUE slots. rt0_go wants R0 = argc, R1 = argv
// (pointer array) in the Unix layout argv…/NULL/envp…/NULL. This stub
// converts: it reserves (argc+1+envc+1)*8 bytes below SP, fills argv[i]
// = argv_block + i*256, then the non-empty env slots. SP stays the g0
// stack top for rt0_go's stack-bounds setup; the array lives below it
// and is read-only input from here on.

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
	// Issue #1540: keep the block's own VA. osinit derives the heap's floor
	// from it (the kernel protects the data aperture through this block, so
	// the break must start past it). R1/R3 stay free for the conversion.
	MOVD	R1, runtime·virArgvBlockBase(SB)
	ADD	$2048, R3, R8 // envp block VA (argv 8*256)

	// Count non-empty env slots (16 × 128 B). Empty = first byte 0.
	MOVD	$0, R7         // envc
	MOVD	$0, R5         // i
count_env:
	CMP	$16, R5
	BHS	count_done
	LSL	$7, R5, R6     // i*128
	ADD	R8, R6, R6
	MOVBU	(R6), R9
	CBZ	R9, count_next
	ADD	$1, R7, R7
count_next:
	ADD	$1, R5, R5
	B	count_env
count_done:

	// bytes = (argc + 1 + envc + 1) * 8
	ADD	R7, R2, R4
	ADD	$2, R4, R4
	LSL	$3, R4, R4
	SUB	R4, RSP, RSP
	MOVD	RSP, R4        // array base

	MOVD	$0, R5         // i
build_argv:
	CMP	R2, R5
	BHS	argv_done
	LSL	$8, R5, R6     // i*256: argv slot stride
	ADD	R3, R6, R6     // &argv_slot[i]
	MOVD	R6, (R4)(R5<<3)
	ADD	$1, R5, R5
	B	build_argv
argv_done:
	MOVD	ZR, (R4)(R5<<3) // argv NULL
	ADD	$1, R5, R5

	MOVD	$0, R9         // env slot i
build_env:
	CMP	$16, R9
	BHS	env_done
	LSL	$7, R9, R6     // i*128
	ADD	R8, R6, R6
	MOVBU	(R6), R10
	CBZ	R10, env_next
	MOVD	R6, (R4)(R5<<3)
	ADD	$1, R5, R5
env_next:
	ADD	$1, R9, R9
	B	build_env
env_done:
	MOVD	ZR, (R4)(R5<<3) // envp NULL

	MOVD	R2, R0         // argc
	MOVD	R4, R1         // argv
	JMP	runtime·rt0_go(SB)
