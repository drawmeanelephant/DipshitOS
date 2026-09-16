// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// GOOS=virelai integrated network poller (issue #1163, phase 2).
//
// REPLACES the phase-0a stub (a copy of plan9 runtime/netpoll_stub.go). The
// stub's defect was structural: netpoll(delay!=0) cleared a note and slept on
// it, then ALWAYS returned an empty gList — so a goroutine parked in
// netpollblock() was never made runnable, and every "blocking" read degraded
// into a spin in the caller. This file is the real poller.
//
// WHAT THE RUNTIME EXPECTS (runtime/netpoll.go, whose core is enabled for
// virelai by tools/go/apply.sh — the core defines netpollGenericInit,
// netpollinited, netpollblock/unblock, netpollready, netpollWaiters and the
// deadline machinery; this file supplies only the platform hooks):
//
//	netpollinit()                      - one-time init
//	netpollopen(fd, pd) int32          - arm notifications for fd
//	netpollclose(fd) int32             - disarm fd
//	netpollarm(pd, mode)               - mode-specific arm (no-op here)
//	netpoll(delay int64) (gList, int32)- the poll
//	netpollBreak()                     - wake the poller (STW/GC safety)
//	netpollIsPollDescriptor(fd) bool
//
// PARK/WAKE CONTRACT (the whole point of phase 2):
//
//   - A goroutine that blocks on I/O does so through the STOCK path:
//     runtime_pollWait -> netpollblock -> gopark. It yields its M; nothing
//     here reimplements that.
//   - This poller observes readiness and calls netpollready(), which runs
//     netpollunblock -> goready, pushing the parked G onto the returned
//     gList. findRunnable injects that list. Readiness therefore makes the
//     parked G RUNNABLE.
//   - The M that runs the blocking netpoll IS the poller M. It waits in the
//     KERNEL (slot 76 sys_sock_ready op 1), which parks that task and lets
//     the other vCPU run Go work (numCPUStartup = 2, ADR 0027 D6). It never
//     spins holding a runnable G: the wait is a scheduler park with a
//     deadline, and the deadline is the worst case if a readiness edge is
//     missed.
//   - netpoll(delay == 0) NEVER blocks. netpoll(delay < 0) is bounded by
//     virPollForeverNs (1 ms) so a missed edge degrades to a 1 ms re-probe
//     latency rather than a wedge; netpollBreak() short-circuits it.
//
// READINESS SOURCE (ADR 0007 amendment, ADR 0009 amendment — appended by
// this change): slot 76 `sys_sock_ready(op, want, timeout_ns)` reports the
// readiness MASK of the calling process's one TCP socket, and (op 1) parks
// the caller until a mask bit is set or the deadline expires. The mask is
// deliberately NOT delivered through the per-process ADR 0009 event queue:
// that FIFO is the application's (window/keyboard) stream and the poller
// must not consume it. This keeps the channel-slot law intact — no epoll,
// no second socket table, no new address family.
//
// HOST-TESTABLE CORE: the park/wake state machine is written once as
// ordinary Go in tools/netpollsm (see its sm.go, and `go test ./...`), and
// mirrored inline below; package runtime may only import internal/runtime/*,
// so it cannot import that package. tools/netpollsm/sm_test.go pins the
// invariants this file must also honour (I1-I6 in that package's doc).

//go:build virelai

package runtime

const (
	virPollMaxEntries = 4
	virPollWantRead   = 1
	virPollWantWrite  = 2
	// virPollEAGAIN is the kernel's EAGAIN (ADR 0007 errno encoding) — the
	// poller is full, so netpollopen refuses the fd honestly.
	virPollEAGAIN = 11
	// virPollForeverNs bounds netpoll(delay<0). The poller re-probes at
	// least this often, so a readiness edge that arrived while nothing was
	// waiting is never lost for more than one bound.
	virPollForeverNs = 1000 * 1000
)

type virPollEntry struct {
	fd    uintptr
	pd    *pollDesc
	inUse bool
}

var (
	virPollLock    mutex
	virPollEntries [virPollMaxEntries]virPollEntry
	virPollBroken  bool
)

// The slot-76 seam (sys_virelai_arm64.s).
//
//go:noescape
func virSockReady(want uintptr) int64

//go:noescape
func virSockWait(want uintptr, timeoutNs int64) int64

func netpollinit() {}

func netpollIsPollDescriptor(fd uintptr) bool { return false }

func netpollopen(fd uintptr, pd *pollDesc) int32 {
	lock(&virPollLock)
	defer unlock(&virPollLock)
	// Re-arm of a known fd replaces the pollDesc (net's fd reuse).
	for i := 0; i < virPollMaxEntries; i++ {
		if virPollEntries[i].inUse && virPollEntries[i].fd == fd {
			virPollEntries[i].pd = pd
			return 0
		}
	}
	for i := 0; i < virPollMaxEntries; i++ {
		if !virPollEntries[i].inUse {
			virPollEntries[i] = virPollEntry{fd: fd, pd: pd, inUse: true}
			return 0
		}
	}
	return virPollEAGAIN
}

func netpollclose(fd uintptr) int32 {
	lock(&virPollLock)
	defer unlock(&virPollLock)
	for i := 0; i < virPollMaxEntries; i++ {
		if virPollEntries[i].inUse && virPollEntries[i].fd == fd {
			virPollEntries[i] = virPollEntry{}
			return 0
		}
	}
	return 0
}

// netpollarm is a no-op: readiness is edge-reported by the kernel socket
// being polled on demand, and the poller re-probes every bound, so there is
// no separate arm step to take.
func netpollarm(pd *pollDesc, mode int) {}

// netpollBreak makes the poller re-probe promptly (STW/GC must never wait a
// full bound for a poller that has nothing to do).
func netpollBreak() {
	lock(&virPollLock)
	virPollBroken = true
	unlock(&virPollLock)
}

// netpoll polls the process's socket. See the PARK/WAKE CONTRACT above.
//
// This may run while the world is stopped, so write barriers are not allowed
// (matching runtime/netpoll.go's netpollready).
func netpoll(delay int64) (gList, int32) {
	var toRun gList

	lock(&virPollLock)
	var ents [virPollMaxEntries]virPollEntry
	for i := 0; i < virPollMaxEntries; i++ {
		ents[i] = virPollEntries[i]
	}
	broken := virPollBroken
	virPollBroken = false
	unlock(&virPollLock)

	if broken {
		// A break is a "come back promptly", not a readiness edge.
		return toRun, 0
	}

	want := uintptr(0)
	live := false
	for i := 0; i < virPollMaxEntries; i++ {
		if ents[i].inUse {
			live = true
			want = virPollWantRead | virPollWantWrite
		}
	}
	if !live {
		// Nothing is armed: no socket, nothing to wait for. Returning
		// immediately (rather than blocking) keeps the scheduler honest
		// before the first netpollopen.
		return toRun, 0
	}

	mask := virSockReady(want)
	if mask < 0 {
		mask = 0
	}
	if mask == 0 && delay != 0 {
		bound := delay
		if delay < 0 || bound > virPollForeverNs {
			bound = virPollForeverNs
		}
		// Reading the break flag again here would race the park below; the
		// bound already caps the worst case, so a break that lands in this
		// window costs at most one bound (documented).
		mask = virSockWait(want, bound)
		if mask < 0 {
			mask = 0
		}
	}

	delta := int32(0)
	for i := 0; i < virPollMaxEntries; i++ {
		if !ents[i].inUse || ents[i].pd == nil {
			continue
		}
		mode := int32(0)
		if mask&virPollWantRead != 0 {
			mode += 'r'
		}
		if mask&virPollWantWrite != 0 {
			mode += 'w'
		}
		if mode != 0 {
			// netpollready -> netpollunblock -> (gList.push, goready):
			// the parked G becomes runnable here.
			delta += netpollready(&toRun, ents[i].pd, mode)
		}
	}
	// Invariant (I6): a non-empty list always carries the matching negative
	// delta, and an empty list always carries 0 — netpollready maintains it.
	// (gList.head is a guintptr, so the empty test is 0, not nil.)
	if toRun.head == 0 {
		delta = 0
	}
	return toRun, delta
}
