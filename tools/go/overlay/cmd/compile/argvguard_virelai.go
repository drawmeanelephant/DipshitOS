// Copyright 2026 The Go Authors.  All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// The argv+envp bss guard for GOOS=virelai cmd/compile.
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
// cmd/compile has no arguments problem in principle, but it failed the
// invariant as linked (measured on the tag-ON image, page slack of the
// writable memsz): slack(-pad) = 0x7b8 (1976) < 0x908 (2312). It therefore
// needs the same pad user/go/sh's argvEnvpGuard applies (that variable's
// comment is the long-form of this one). A compiler invoked with a source
// file and flags is non-negotiable here, so this is not a nicety.
//
// The size is chosen against that measurement: 0x7b8 - 0x9b0 wraps to 0xE08
// (3592) of slack, which clears 0x908 with 1280 bytes to spare. tools/go/
// build-gotool.sh asserts the invariant from the linked ELF; if a future
// change trips that assert, this is the array to resize.
package main

var argvEnvpGuard [0x9b0]byte

func init() {
	// A store with a runtime-computed value keeps the pad in the bss: the
	// linker dead-codes an unreferenced, constant-folded package var, so a
	// bare declaration would pad nothing.
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}
