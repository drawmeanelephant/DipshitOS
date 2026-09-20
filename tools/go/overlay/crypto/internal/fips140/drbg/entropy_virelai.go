// Copyright 2026 The Go Authors.  All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// The toolchain-image FIPS entropy stub for GOOS=virelai.
//
// This file exists only to satisfy a LINK, and it is selected only when the
// builder opts in. The `_virelai` name supplies the GOOS half of the
// constraint; the directive below supplies the opt-in half. A Go file's name
// suffix and its //go:build line are both enforced, and they AND together —
// the same rule that stops upstream's entropy_wasm.go from being reused here,
// since `_wasm` pins that file to wasm whatever its build line says.
//
// Why the pairing exists. crypto/internal/fips140 pulls in this package, so
// entropy_fips140.go — which declares a 32 MiB .noptrbss scratch buffer — is
// linked into cmd/compile and cmd/link even though crypto/rand and crypto/tls
// are ABSENT from both closures (measured with go list -deps: crypto/rand=0,
// crypto/tls=0, fips140/drbg=1). The kernel's exec acceptance bound
// (elf.zig load_max tint) sums EVERY PT_LOAD memsz, so it charges that
// address space as memory and refuses the image with segment_too_large.
// apply.sh therefore excludes entropy_fips140.go under this same tag, and
// that exclusion is what creates the hole this file fills: entropy_fips140.go
// is the ONLY definition of getEntropy, which rand.go calls at lines 26 and
// 73.
//
// This is deliberately NOT a real entropy source and deliberately NOT
// GOOS-wide. A virelai guest must keep a working crypto/rand — M47/M67 landed
// TLS and DNS on it — so the default GOOS=virelai path keeps
// entropy_fips140.go and its buffer, and only the two toolchain images (built
// with -tags virelaitoolchain) see this Gated stub. The guest's own
// randomness comes from syscall.Getrandom over the kernel's slot 72.
//
// Panicking is the whole point. Nothing on the cmd/compile or cmd/link happy
// path calls this — those two images link the DRBG purely as dead weight — so
// a call would mean the assumption above was wrong. That must fail LOUDLY
// rather than quietly seed a DRBG from nothing.
//
//go:build virelaitoolchain

package drbg

// getEntropy stands in for the FIPS 140-3 entropy source when a toolchain
// image is built. It never returns.
func getEntropy() *[SeedSize]byte {
	panic("virelaitoolchain: FIPS 140-3 entropy generation is not supported in the toolchain images")
}
