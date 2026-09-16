// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

//go:build virelai

// The GOOS=virelai EL0 clock (phase 2.1). CNTPCT_EL0/CNTFRQ_EL0 are
// EL0-readable (kernel/src/timer.zig allow_el0_counter arms
// CNTKCTL_EL1.EL0PCTEN|EL0VCTEN), so a virelai program reads time with no
// syscall slot — the same pair the runtime's nanotime1 uses.

#include "textflag.h"

// func virCounterTicks() uint64 — CNTPCT_EL0, the free-running counter.
TEXT ·virCounterTicks(SB),NOSPLIT|NOFRAME,$0-8
	MRS	CNTPCT_EL0, R0
	MOVD	R0, ret+0(FP)
	RET

// func virCounterFreq() uint64 — CNTFRQ_EL0, the counter frequency in Hz
// (read-only; Virtualization.framework picks it).
TEXT ·virCounterFreq(SB),NOSPLIT|NOFRAME,$0-8
	MRS	CNTFRQ_EL0, R0
	MOVD	R0, ret+0(FP)
	RET
