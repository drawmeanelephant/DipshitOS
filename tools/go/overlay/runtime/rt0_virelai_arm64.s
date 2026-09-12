// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// GOOS=virelai entry (issue #1163, phase 0a).
//
// The kernel's exec passes R0=argc / R1=argv in ITS OWN slot-based argv
// shape (not a SysV char* array) and no auxv, so the virelai rt0 ignores
// both: argc=0/argv=nil (phase 0b will wire real argv through the entry
// contract). rt0_go's contract is SP = stack, R0 = argc, R1 = argv.
// Symbol naming follows the linker's entry convention: arch first
// (_rt0_arm64_linux, not _rt0_linux_arm64).

#include "textflag.h"

TEXT _rt0_arm64_virelai(SB),NOSPLIT|NOFRAME,$0-0
	MOVD	$0, R0
	MOVD	$0, R1
	JMP	runtime·rt0_go(SB)
