// Copyright 2022 The Go Authors.  All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build virelai

package mmap

import (
	"io"
	"os"
)

// GOOS=virelai has no file-backed mapping, so this is the same shape as
// mmap_other.go: read the whole file into a Go-allocated buffer and hand that
// back as Data.Data.
//
// The reason is structural, not a missing wiring step. The kernel's mapping
// slot is sys_mmap(addr, len, prot, flags) (ADR 0007 slot 63, kernel/src/
// syscall.zig:handle_mmap) and it has NO file-descriptor argument at all: it
// maps anonymous memory and nothing else, with MAP_ANONYMOUS implied rather
// than selected. There is therefore no call this port could forward to — a
// file-backed mmap is not a slot this GOOS is missing, it is a slot the ABI
// does not express. Inventing a mapping over sys_mmap would mean copying the
// file into anonymous pages and calling the result a mapping.
//
// What that costs, stated plainly: telemetry's counter file is opened
// read-write and shared, and the code above it increments counters with
// atomic compare-and-swap on Data.Data (internal/counter/file.go:cas32) so
// that concurrent processes see each other's counts. A buffer is private, so
// those writes are visible to this process and are NOT persisted back to the
// file, and a second process would not see them. Upstream accepts exactly
// this degradation for js/wasm, wasip1 and plan9; virelai joins that set
// rather than being special-cased. Nothing in cmd/compile's own execution
// depends on the persistence.
//
// mmapFile is not a stub and never fails on its own account: a read error is
// the caller's to see, and an empty file yields empty Data, which the counter
// code already guards (load32 bounds-checks against len(mapping.Data)).
func mmapFile(f *os.File) (*Data, error) {
	b, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	return &Data{f, b, nil}, nil
}

// munmapFile is a no-op because the buffer belongs to the Go heap, not to a
// kernel mapping: there is nothing to unmap, and the file handle is closed by
// the caller (internal/counter/file.go's mappedFile.close) rather than here
// — the same division of labour as mmap_other.go.
func munmapFile(_ *Data) error {
	return nil
}
