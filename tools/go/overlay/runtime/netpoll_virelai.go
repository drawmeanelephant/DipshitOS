// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// GOOS=virelai netpoll stub (issue #1163, phase 0a) — a copy of
// runtime/netpoll_stub.go (plan9): fully blocking I/O, no integrated
// poller. Phase 0b/2 wires the kernel's event seam (ADR 0009) into a
// real netpoll.

//go:build virelai

package runtime

import "internal/runtime/atomic"

var netpollInited atomic.Uint32

var netpollStubLock mutex
var netpollNote note

// netpollBroken, protected by netpollBrokenLock, avoids a double notewakeup.
var netpollBrokenLock mutex
var netpollBroken bool

func netpollGenericInit() {
	netpollInited.Store(1)
}

func netpollBreak() {
	lock(&netpollBrokenLock)
	broken := netpollBroken
	netpollBroken = true
	if !broken {
		notewakeup(&netpollNote)
	}
	unlock(&netpollBrokenLock)
}

// Polls for ready network connections.
// Returns a list of goroutines that become runnable,
// and a delta to add to netpollWaiters.
// This must never return an empty list with a non-zero delta.
func netpoll(delay int64) (gList, int32) {
	// Implementation for platforms that do not support
	// integrated network poller.
	if delay != 0 {
		// This lock ensures that only one goroutine tries to use
		// the note. It should normally be completely uncontended.
		lock(&netpollStubLock)

		lock(&netpollBrokenLock)
		noteclear(&netpollNote)
		netpollBroken = false
		unlock(&netpollBrokenLock)

		notetsleep(&netpollNote, delay)
		unlock(&netpollStubLock)
		// Guard against starvation in case the lock is contended
		// (eg when running TestNetpollBreak).
		osyield()
	}
	return gList{}, 0
}

func netpollinited() bool {
	return netpollInited.Load() != 0
}

func netpollAnyWaiters() bool {
	return false
}

func netpollAdjustWaiters(delta int32) {
}
