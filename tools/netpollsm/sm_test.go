package netpollsm

import (
	"sync"
	"testing"
)

func TestSM_RegisterAndLookupByFD(t *testing.T) {
	p := New()
	if _, err := p.Open(0); err != ErrInvalidFD {
		t.Fatalf("Open(0) err = %v, want ErrInvalidFD", err)
	}
	if _, err := p.Open(-3); err != ErrInvalidFD {
		t.Fatalf("Open(-3) err = %v, want ErrInvalidFD", err)
	}
	d, err := p.Open(7)
	if err != nil {
		t.Fatalf("Open(7): %v", err)
	}
	if d.State() != StateNil {
		t.Fatalf("fresh desc state = %v, want StateNil", d.State())
	}
	if got := p.Lookup(7); got != d {
		t.Fatalf("Lookup(7) = %p, want %p", got, d)
	}
	again, err := p.Open(7)
	if err != nil || again != d {
		t.Fatalf("Open(7) twice must be idempotent, got (%p,%v)", again, err)
	}
}

func TestSM_ParkThenReadyWakes(t *testing.T) {
	p := New()
	d, _ := p.Open(3)

	park, err := p.Wait(d, Read)
	if err != nil || !park {
		t.Fatalf("Wait = (%v,%v), want (true,nil)", park, err)
	}
	if d.State() != StateWait {
		t.Fatalf("state after Wait = %v, want StateWait", d.State())
	}
	if p.Waiters() != 1 {
		t.Fatalf("waiters = %d, want 1", p.Waiters())
	}

	w, woke := p.Ready(3, Read)
	if !woke {
		t.Fatal("Ready on a parked desc must wake it")
	}
	if w.FD != 3 || w.Mode != Read {
		t.Fatalf("wake = %+v, want {3 Read}", w)
	}
	if d.State() != StateReady {
		t.Fatalf("state after Ready = %v, want StateReady", d.State())
	}

	out, delta := p.Drain()
	if len(out) != 1 || out[0].FD != 3 {
		t.Fatalf("Drain = %+v, want one wake on fd 3", out)
	}
	if delta != -1 {
		t.Fatalf("delta = %d, want -1", delta)
	}
	if d.State() != StateNil {
		t.Fatalf("state after Drain = %v, want StateNil", d.State())
	}
	if p.Waiters() != 0 {
		t.Fatalf("waiters after Drain = %d, want 0", p.Waiters())
	}
}

func TestSM_AlreadyReadyFastPath(t *testing.T) {
	p := New()
	d, _ := p.Open(9)
	// A readiness edge with no waiter is dropped (I3: only pdWait wakes).
	if _, woke := p.Ready(9, Read); woke {
		t.Fatal("Ready with no waiter must not report a wake")
	}
	park, err := p.Wait(d, Read)
	if err != nil || !park {
		t.Fatalf("first Wait = (%v,%v), want (true,nil)", park, err)
	}
	if _, woke := p.Ready(9, Read); !woke {
		t.Fatal("Ready must wake the parked waiter")
	}
	// The waiter was woken; before anyone drains, it re-arms and must take
	// the fast path (state is StateReady).
	park, err = p.Wait(d, Read)
	if err != nil {
		t.Fatalf("second Wait err = %v", err)
	}
	if park {
		t.Fatal("already-ready descriptor must NOT park (fast path)")
	}
	if d.State() != StateNil {
		t.Fatalf("fast path must consume readiness, state = %v", d.State())
	}
}

func TestSM_SpuriousWakeupNoLostWake(t *testing.T) {
	p := New()
	d, _ := p.Open(11)
	for i := 0; i < 5; i++ {
		if _, woke := p.Ready(11, Read); woke {
			t.Fatalf("spurious Ready #%d reported a wake", i)
		}
	}
	if p.Wakes() != 0 {
		t.Fatalf("wakes = %d after spurious edges, want 0", p.Wakes())
	}
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("Wait after spurious edges must arm")
	}
	if _, woke := p.Ready(11, Read); !woke {
		t.Fatal("real edge after spurious edges must wake")
	}
	if p.Wakes() != 1 {
		t.Fatalf("wakes = %d, want exactly 1", p.Wakes())
	}
}

func TestSM_DoubleReadyDoesNotDoubleWake(t *testing.T) {
	p := New()
	d, _ := p.Open(13)
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("Wait must arm")
	}
	if _, woke := p.Ready(13, Read); !woke {
		t.Fatal("first edge must wake")
	}
	if _, woke := p.Ready(13, Read); woke {
		t.Fatal("second edge on a StateReady desc must be a no-op")
	}
	if p.Wakes() != 1 {
		t.Fatalf("wakes = %d, want 1", p.Wakes())
	}
}

func TestSM_DoubleWaitRejected(t *testing.T) {
	p := New()
	d, _ := p.Open(17)
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("first Wait must arm")
	}
	if _, err := p.Wait(d, Write); err != ErrDoubleWait {
		t.Fatalf("second Wait err = %v, want ErrDoubleWait", err)
	}
}

func TestSM_CloseWhileParkedWakes(t *testing.T) {
	p := New()
	d, _ := p.Open(19)
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("Wait must arm")
	}
	woke, err := p.Close(19)
	if err != nil {
		t.Fatalf("Close: %v", err)
	}
	if !woke {
		t.Fatal("Close on a parked descriptor must report a wake (I5)")
	}
	if !d.Closing() {
		t.Fatal("Closing() must be true after Close during park")
	}
	if p.Lookup(19) != nil {
		t.Fatal("closed fd must be gone from the registry")
	}
	if _, err := p.Close(19); err != ErrNotRegistered {
		t.Fatalf("second Close err = %v, want ErrNotRegistered", err)
	}
}

func TestSM_NeverEmptyListWithNonzeroDelta(t *testing.T) {
	p := New()
	out, delta := p.Drain()
	if len(out) != 0 {
		t.Fatalf("Drain on empty poller = %+v", out)
	}
	if delta != 0 {
		t.Fatalf("empty Drain delta = %d, want 0", delta)
	}
	d, _ := p.Open(23)
	if park, _ := p.Wait(d, Write); !park {
		t.Fatal("Wait must arm")
	}
	if _, woke := p.Ready(23, Write); !woke {
		t.Fatal("Ready must wake")
	}
	if _, delta := p.Drain(); delta != -1 {
		t.Fatalf("first Drain delta = %d, want -1", delta)
	}
	if out, delta := p.Drain(); len(out) != 0 || delta != 0 {
		t.Fatalf("second Drain = (%+v,%d), want (nil,0)", out, delta)
	}
}

func TestSM_MultiFDOneEvent(t *testing.T) {
	p := New()
	var descs []*Desc
	for _, fd := range []int32{31, 32, 33} {
		d, _ := p.Open(fd)
		descs = append(descs, d)
		if park, _ := p.Wait(d, Read); !park {
			t.Fatalf("Wait fd %d must arm", fd)
		}
	}
	if _, woke := p.Ready(32, Read); !woke {
		t.Fatal("Ready(32) must wake")
	}
	out, delta := p.Drain()
	if len(out) != 1 || out[0].FD != 32 {
		t.Fatalf("Drain = %+v, want exactly {32}", out)
	}
	if delta != -1 {
		t.Fatalf("delta = %d, want -1", delta)
	}
	if descs[0].State() != StateWait || descs[2].State() != StateWait {
		t.Fatal("unready descriptors must remain parked")
	}
	if p.Waiters() != 2 {
		t.Fatalf("waiters = %d, want 2", p.Waiters())
	}
}

func TestSM_ConcurrentReadyDuringPark(t *testing.T) {
	p := New()
	for i := 0; i < 64; i++ {
		fd := int32(100 + i)
		d, _ := p.Open(fd)
		if park, _ := p.Wait(d, Read); !park {
			t.Fatalf("Wait(%d) must arm", fd)
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func(fd int32) { defer wg.Done(); p.Ready(fd, Read) }(int32(100 + i))
	}
	wg.Wait()
	out, delta := p.Drain()
	if len(out) != 64 {
		t.Fatalf("Drain = %d wakes, want 64", len(out))
	}
	if delta != -64 {
		t.Fatalf("delta = %d, want -64", delta)
	}
	if p.Waiters() != 0 {
		t.Fatalf("waiters = %d, want 0", p.Waiters())
	}
}

func TestSM_BreakDedupes(t *testing.T) {
	p := New()
	if !p.Break() {
		t.Fatal("first Break must report a real wake")
	}
	if p.Break() {
		t.Fatal("second Break must dedupe (no double notewakeup)")
	}
	if !p.Broken() {
		t.Fatal("Broken must be true")
	}
	p.ClearBreak()
	if p.Broken() || !p.Break() {
		t.Fatal("after ClearBreak a Break must fire again")
	}
}

func TestSM_ZeroDelayNonBlocking(t *testing.T) {
	p := New()
	d, _ := p.Open(41)
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("Wait must arm")
	}
	out, delta := p.Drain()
	if len(out) != 0 || delta != 0 {
		t.Fatalf("non-blocking drain with no readiness = (%+v,%d), want (nil,0)", out, delta)
	}
	if d.State() != StateWait {
		t.Fatalf("non-blocking drain must leave the waiter armed, state = %v", d.State())
	}
}

func TestSM_ShutdownUnregisters(t *testing.T) {
	p := New()
	d, _ := p.Open(43)
	if park, _ := p.Wait(d, Read); !park {
		t.Fatal("Wait must arm")
	}
	p.Shutdown()
	if _, err := p.Open(45); err != ErrNotRegistered {
		t.Fatalf("Open after Shutdown err = %v, want ErrNotRegistered", err)
	}
	if _, err := p.Wait(d, Read); err != ErrNotRegistered {
		t.Fatalf("Wait after Shutdown err = %v, want ErrNotRegistered", err)
	}
}
