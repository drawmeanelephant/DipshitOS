// Package netpollsm is the host-testable *core* of the GOOS=virelai netpoll
// (issue #1163, phase 2, tools/go/netpoll).
//
// WHY THIS EXISTS
// ---------------
// The real netpoll lives in `tools/go/overlay/runtime/netpoll_virelai.go`,
// which lands in the fork as `package runtime` (build tag `virelai`) and can
// therefore ONLY run on-target, inside the VZ gate. Every mistake in the
// park/wake bookkeeping there shows up as a wedged scheduler or a lost
// wakeup, which is expensive to bisect through a VM boot.
//
// So the state machine is written once, here, as ordinary Go with no runtime
// internals: fd -> pollDesc registration, the pdNil/pdWait/pdReady register
// that the runtime already uses (runtime/netpoll.go), park/wake transitions,
// the "wake exactly once" rule, and the invariant that a non-empty gList is
// the ONLY way the runtime learns a delta. It is exercised by `go test ./...`
// on the host (see sm_test.go) with zero VZ dependency.
//
// The runtime overlay reimplements the same transitions inline (package
// runtime may only import internal/runtime/*, so it cannot import this
// package); the invariant list below is the contract both must satisfy:
//
//	I1. A descriptor is in exactly one of pdNil | pdWait | pdReady.
//	I2. Wait() returns park=true only when the descriptor is armed (pdWait);
//	    an already-ready descriptor consumes the readiness and returns
//	    park=false (the fast path).
//	I3. Ready() makes a pdWait descriptor pdReady and reports that a goroutine
//	    must be woken; on a pdReady descriptor it is a no-op (no lost double
//	    wake, no duplicate goready).
//	I4. Wake count == number of pdWait -> pdReady transitions. Spurious
//	    readiness (Ready on pdNil/pdReady) never inflates it.
//	I5. Close() on a parked descriptor is a wake: the parked goroutine must
//	    run again and observe the close, never sleep forever.
//	I6. A drain that returns no woken descriptors must report delta 0, so the
//	    runtime never adds waiters for a poll that woke nobody.
package netpollsm

import (
	"errors"
	"sync"
)

// State mirrors runtime's pdNil/pdWait/pdReady (runtime/netpoll.go).
type State int32

const (
	// StateNil: not registered / closed.
	StateNil State = -1
	// StateWait: a goroutine is (or is about to be) parked here.
	StateWait State = 0
	// StateReady: a readiness event arrived; the next consumer runs.
	StateReady State = 1
)

// Mode is the poll direction, mirroring runtime's 'r'/'w'.
type Mode uint8

const (
	// Read is the read-readiness direction.
	Read Mode = 'r'
	// Write is the write-readiness direction.
	Write Mode = 'w'
)

// Errors returned to the (on-target) caller.
var (
	// ErrNotRegistered is returned for an fd/desc that was never opened.
	ErrNotRegistered = errors.New("netpollsm: descriptor not registered")
	// ErrDoubleWait is returned when two goroutines wait on one descriptor.
	ErrDoubleWait = errors.New("netpollsm: descriptor already has a waiter")
	// ErrInvalidFD is returned for a negative/zero fd.
	ErrInvalidFD = errors.New("netpollsm: invalid fd")
)

// Desc is one polled descriptor (runtime: pollDesc).
type Desc struct {
	fd    int32
	state State
	// rg/wg record the direction the parked waiter asked for, so Read/Wait
	// and Write/Ready pairs stay consistent (mirrors pd.rg/pd.wg).
	rg Mode
	wg Mode
	// closing is set by Close so a woken waiter can distinguish
	// close-during-park from a plain readiness edge.
	closing bool
}

// FD reports the descriptor's fd.
func (d *Desc) FD() int32 { return d.fd }

// State reports the current tri-state.
func (d *Desc) State() State { return d.state }

// Closing reports whether Close ran while a goroutine was parked here.
func (d *Desc) Closing() bool { return d.closing }

// Wake records one goroutine that became runnable because of this poll.
type Wake struct {
	FD   int32
	Mode Mode
}

// Poller is the registry + bookkeeping core (runtime: the netpoll globals).
type Poller struct {
	mu      sync.Mutex
	descs   map[int32]*Desc
	waiters int32
	wakes   int64 // monotonic count of pdWait -> pdReady transitions
	broken  bool
	closed  bool
}

// New returns an empty poller.
func New() *Poller { return &Poller{descs: make(map[int32]*Desc)} }

// Open registers fd (idempotent, like netpollopen on an fd already known).
func (p *Poller) Open(fd int32) (*Desc, error) {
	if fd <= 0 {
		return nil, ErrInvalidFD
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil, ErrNotRegistered
	}
	if d, ok := p.descs[fd]; ok {
		return d, nil
	}
	d := &Desc{fd: fd, state: StateNil}
	p.descs[fd] = d
	return d, nil
}

// Lookup returns the descriptor for fd, or nil.
func (p *Poller) Lookup(fd int32) *Desc {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.descs[fd]
}

// Close unregisters fd. I5: if a goroutine is parked (pdWait) it becomes
// runnable with Closing set, so the waiter observes the close instead of
// sleeping forever. Returns (woke, error).
func (p *Poller) Close(fd int32) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	d, ok := p.descs[fd]
	if !ok {
		return false, ErrNotRegistered
	}
	woke := false
	if d.state == StateWait {
		d.closing = true
		d.state = StateReady
		p.wakes++
		woke = true
	}
	d.state = StateNil
	d.closing = true
	delete(p.descs, fd)
	return woke, nil
}

// Wait arms the descriptor for a park. I2: an already-ready descriptor
// consumes the readiness and returns park=false (the fast path); a pdNil
// descriptor is an error (the runtime never waits on an unregistered fd).
//
// It is the caller's (runtime's) job to actually gopark; this returns the
// decision only.
func (p *Poller) Wait(d *Desc, m Mode) (park bool, err error) {
	if d == nil {
		return false, ErrNotRegistered
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return false, ErrNotRegistered
	}
	if _, ok := p.descs[d.fd]; !ok {
		return false, ErrNotRegistered
	}
	switch d.state {
	case StateReady:
		// Consume the readiness; the waiter must NOT park.
		d.state = StateNil
		return false, nil
	case StateWait:
		// Two goroutines on one desc is a caller bug, never a silent park.
		return false, ErrDoubleWait
	default:
		d.state = StateWait
		if m == Read {
			d.rg = m
		} else {
			d.wg = m
		}
		p.waiters++
		return true, nil
	}
}

// Ready delivers a readiness edge for fd in direction m. I3/I4: pdWait ->
// pdReady wakes exactly one goroutine; pdNil/pdReady is a silent no-op.
func (p *Poller) Ready(fd int32, m Mode) (Wake, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	d, ok := p.descs[fd]
	if !ok || d.state != StateWait {
		return Wake{}, false
	}
	d.state = StateReady
	p.wakes++
	return Wake{FD: fd, Mode: m}, true
}

// Drain is the netpoll(delay=0) equivalent: collect every currently-ready
// descriptor and reset it to pdNil. I6: an empty result carries delta 0.
func (p *Poller) Drain() ([]Wake, int32) {
	p.mu.Lock()
	defer p.mu.Unlock()
	var out []Wake
	for _, d := range p.descs {
		if d.state == StateReady {
			m := d.rg
			if m == 0 {
				m = d.wg
			}
			out = append(out, Wake{FD: d.fd, Mode: m})
			d.state = StateNil
			d.rg, d.wg = 0, 0
		}
	}
	if len(out) == 0 {
		// I6: never report a delta for a poll that woke nobody.
		return nil, 0
	}
	p.waiters -= int32(len(out))
	if p.waiters < 0 {
		p.waiters = 0
	}
	return out, -int32(len(out))
}

// Waiters reports the current parked-waiter count (runtime: netpollWaiters).
func (p *Poller) Waiters() int32 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.waiters
}

// Wakes reports the monotonic wake count (test observability).
func (p *Poller) Wakes() int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.wakes
}

// Break mirrors netpollBreak: deduped, and observable so the runtime's STW
// path can prove it did not deadlock.
func (p *Poller) Break() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	was := p.broken
	p.broken = true
	return !was
}

// ClearBreak resets the break flag (the poller consumed it).
func (p *Poller) ClearBreak() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.broken = false
}

// Broken reports the break flag.
func (p *Poller) Broken() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.broken
}

// Shutdown closes the poller (goenvs/exit paths).
func (p *Poller) Shutdown() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closed = true
	p.descs = make(map[int32]*Desc)
}
