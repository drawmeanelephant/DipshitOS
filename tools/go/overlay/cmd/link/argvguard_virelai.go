// Copyright 2026 The Go Authors.  All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// The argv+envp bss guard for GOOS=virelai cmd/link.
//
// The kernel packs the argv+envp block (256 + 2048 bytes, kernel
// exec.arg_block_bytes + env_block_bytes) into the image's writable segment
// tail and extends the data aperture's mmap-collision bound through it
// (kernel/src/process.zig mmap_collides, issue #1214). The GOOS=virelai sbrk
// break starts at memRound(moduledata.end), so a bss end that lands inside
// that bound refuses the runtime's very FIRST mmap and kills mallocinit
// before main runs. The invariant is therefore geometric, not a preference:
// the writable segment must keep at least 0x908 bytes of distance to its
// page end.
//
// cmd/link failed it as linked. Measured on the tag-ON image
// (check: the writable memsz page slack, tools/go/build-gosh.sh's rule):
//
//     writable memsz = 0x69cb0 (433,328)  page slack = 0x350 (848)  need 0x908
//
// 848 < 2312, so an exec WITH arguments refuses; a linker with no arguments
// is not a linker. This pad restores the invariant the same way user/go/sh's
// argvEnvpGuard does (that variable's comment is the long-form of this one).
//
// cmd/compile does NOT carry a pad: its writable memsz is 0x298668, slack
// 0x998 (2456) >= 0x908. That margin is only 144 bytes, so the toolchain
// build recipe ASSERTS the invariant for both images rather than trusting
// this comment — if a future change trips it, the build says so by name
// instead of the guest dying mysteriously in mallocinit.
//
// The size is chosen against the measured slack, not guessed: 848 + 0x9b0
// lands the segment's remainder at 0x660, i.e. 2464 bytes of slack, which
// clears 0x908 with room to spare. If the toolchain recipe's assert ever
// trips, this is the array to resize.
package main

var argvEnvpGuard [0x9b0]byte

func init() {
	// A store with a runtime-computed value keeps the pad in the bss: the
	// linker dead-codes an unreferenced, constant-folded package var, so a
	// bare declaration would pad nothing.
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}
