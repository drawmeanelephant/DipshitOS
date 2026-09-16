package vsys

import (
	"errors"
	"testing"
)

func resetConn(t *testing.T) {
	t.Helper()
	ClientLive = nil
	t.Cleanup(func() { ClientLive = nil })
}

func TestParseIPv4_Literals(t *testing.T) {
	ok := map[string][4]byte{
		"10.0.2.2":        {10, 0, 2, 2},
		"127.0.0.1":       {127, 0, 0, 1},
		"255.255.255.255": {255, 255, 255, 255},
		"0.0.0.0":         {0, 0, 0, 0},
	}
	for s, want := range ok {
		got, err := ParseIPv4(s)
		if err != nil || got != want {
			t.Fatalf("ParseIPv4(%q) = (%v,%v), want %v", s, got, err, want)
		}
	}
	for _, bad := range []string{"example.com", "localhost", "1.2.3", "1.2.3.4.5", "256.1.1.1",
		"1.2.3.", ".1.2.3", "::1", "10.0.2.2:80", " 10.0.2.2"} {
		if _, err := ParseIPv4(bad); err != ErrNotIPLiteral {
			t.Fatalf("ParseIPv4(%q) = %v, want ErrNotIPLiteral", bad, err)
		}
	}
}

func TestDial_RejectsHostnameBeforeSyscall(t *testing.T) {
	resetConn(t)
	called := false
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { called = true; return 0 })
	if _, err := Dial("example.com", 80); err != ErrNotIPLiteral {
		t.Fatalf("Dial(hostname) = %v, want ErrNotIPLiteral", err)
	}
	if called {
		t.Fatal("Dial must reject a hostname before any syscall")
	}
}

func TestDial_OneConnPerProcess(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	c1, err := Dial("10.0.2.2", 8080)
	if err != nil {
		t.Fatalf("first Dial: %v", err)
	}
	c2, err := Dial("10.0.2.2", 8080)
	if err != ErrConnBusy {
		t.Fatalf("second Dial err = %v, want ErrConnBusy", err)
	}
	if c2 != nil {
		t.Fatal("second Dial must return a nil Conn")
	}
	if ClientLive != c1 {
		t.Fatal("ClientLive must still be the first Conn")
	}
}

func TestConn_CloseThenDialAgain(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	c1, err := Dial("10.0.2.2", 8080)
	if err != nil {
		t.Fatalf("first Dial: %v", err)
	}
	if err := c1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if ClientLive != nil {
		t.Fatal("Close must clear the process's live Conn")
	}
	if _, err := Dial("10.0.2.2", 9090); err != nil {
		t.Fatalf("Dial after Close must succeed, got %v", err)
	}
}

func TestConn_ReadAfterCloseIsConnClosed(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	c, _ := Dial("10.0.2.2", 80)
	_ = c.Close()
	if _, err := c.Read(make([]byte, 4)); err != ErrConnClosed {
		t.Fatalf("Read after Close = %v, want ErrConnClosed", err)
	}
}

func TestConn_ReadFailsClosedWhenPeerGoesAway(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			if a1 == 1 {
				return 1 // readable (op is 0: probe)
			}
			return 0
		case SlotTCPRecv:
			return 0 // readable-but-empty: the peer FIN was consumed
		}
		return 0
	})
	c, err := Dial("10.0.2.2", 80)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	_, err = c.Read(make([]byte, 16))
	if err != ErrPeerClosed {
		t.Fatalf("Read after peer close = %v, want ErrPeerClosed (fail closed)", err)
	}
	// The failure is sticky: a second Read fails closed again, not by
	// re-blocking on a socket that will never be readable.
	if _, err := c.Read(make([]byte, 16)); err != ErrPeerClosed {
		t.Fatalf("second Read = %v, want ErrPeerClosed", err)
	}
	if _, err := c.Write([]byte("GET / HTTP/1.0\r\n\r\n")); err != ErrPeerClosed {
		t.Fatalf("Write after peer close = %v, want ErrPeerClosed", err)
	}
}

func TestConn_ReadTimesOutWhenNeverReadable(t *testing.T) {
	// The wait is bounded by the WALL-CLOCK deadline (vsys.Nanotime), and
	// each park advances the injected clock by one tick (1 s): a 2 s budget
	// therefore pays 3 probes and 2 parks before failing closed.
	resetConn(t)
	now := int64(0)
	fakeClock(t, func() int64 { return now })
	probes, sleeps := 0, 0
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			probes++ // never readable
		case SlotSleep:
			sleeps++
			now += 1_000_000_000
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	c.SetReadDeadline(2_000_000_000) // 2 s of wall clock
	_, err := c.Read(make([]byte, 16))
	if !errors.Is(err, error(Errno(ErrETIMEDOUT))) {
		t.Fatalf("Read on a never-readable socket = %v, want Errno(ETIMEDOUT)", err)
	}
	if probes != 3 || sleeps != 2 {
		t.Fatalf("bounded wait = %d probes / %d parks, want 3 / 2", probes, sleeps)
	}
}

func TestConn_ReadExpiredDeadlineFailsOnFirstPoll(t *testing.T) {
	// The clock made the deadline absolute: a budget that has already
	// elapsed costs ONE probe and ZERO parks, instead of a whole tick.
	resetConn(t)
	now := int64(0)
	fakeClock(t, func() int64 { return now })
	probes, sleeps := 0, 0
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			probes++
		case SlotSleep:
			sleeps++
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	c.SetReadDeadline(1_000_000_000) // absolute deadline = 1 s
	now = 5_000_000_000              // ... and the clock is already 4 s past it
	_, err := c.Read(make([]byte, 16))
	if !errors.Is(err, error(Errno(ErrETIMEDOUT))) {
		t.Fatalf("Read with an elapsed deadline = %v, want Errno(ETIMEDOUT)", err)
	}
	if probes != 1 || sleeps != 0 {
		t.Fatalf("elapsed deadline cost %d probes / %d parks, want 1 / 0", probes, sleeps)
	}
}

func TestConn_ReadDefaultBudgetIsThirtySeconds(t *testing.T) {
	resetConn(t)
	now := int64(0)
	fakeClock(t, func() int64 { return now })
	probes, sleeps := 0, 0
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			probes++
		case SlotSleep:
			sleeps++
			now += 1_000_000_000
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	// No SetReadDeadline: DefaultReadBudgetNs (30 s) applies.
	_, err := c.Read(make([]byte, 16))
	if !errors.Is(err, error(Errno(ErrETIMEDOUT))) {
		t.Fatalf("Read = %v, want Errno(ETIMEDOUT)", err)
	}
	if probes != 31 || sleeps != 30 {
		t.Fatalf("default budget = %d probes / %d parks, want 31 / 30", probes, sleeps)
	}
}

func TestConn_ReadYieldsWhileWaiting(t *testing.T) {
	// The bounded wait must PARK (sys_sleep) between probes: that is what
	// keeps the other goroutine alive while this Read is blocked. The
	// heartbeat-during-load proof depends on it.
	resetConn(t)
	now := int64(0)
	fakeClock(t, func() int64 { return now })
	order := []string{}
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			order = append(order, "probe")
			return 0
		case SlotSleep:
			order = append(order, "park")
			now += 1_000_000_000
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	c.SetReadDeadline(3_000_000_000)
	_, _ = c.Read(make([]byte, 8))
	want := []string{"probe", "park", "probe", "park", "probe", "park", "probe"}
	if len(order) != len(want) {
		t.Fatalf("probe/park order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("probe/park order = %v, want %v", order, want)
		}
	}
}

func TestConn_ReadDeliversQueuedBytes(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotSockReady:
			return 1
		case SlotTCPRecv:
			return 42
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	n, err := c.Read(make([]byte, 64))
	if err != nil || n != 42 {
		t.Fatalf("Read = (%d,%v), want (42,nil)", n, err)
	}
}

func TestConn_WriteTruncatesAtPayloadMax(t *testing.T) {
	// Truncation is reported, never silent: the caller sees the count it
	// sent AND ErrShortWrite (the io.Writer convention).
	resetConn(t)
	var sent uintptr
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotTCPSend {
			sent = a1
			return int64(a1)
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	n, err := c.Write(make([]byte, TCPPayloadMax+100))
	if err != ErrShortWrite {
		t.Fatalf("Write over payload_max err = %v, want ErrShortWrite", err)
	}
	if sent != TCPPayloadMax || n != TCPPayloadMax {
		t.Fatalf("Write sent %d/%d bytes, want %d (payload_max)", sent, n, TCPPayloadMax)
	}
}

func TestConn_WriteShortWriteWhenKernelTruncates(t *testing.T) {
	// A kernel partial send is reported too, not mistaken for success.
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotTCPSend {
			return int64(a1) - 10 // the transmit path truncated
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	n, err := c.Write([]byte("GET / HTTP/1.0\r\n\r\n"))
	if err != ErrShortWrite {
		t.Fatalf("partial send err = %v, want ErrShortWrite", err)
	}
	if n != len("GET / HTTP/1.0\r\n\r\n")-10 {
		t.Fatalf("partial send n = %d, want %d", n, len("GET / HTTP/1.0\r\n\r\n")-10)
	}
}

func TestConn_WriteFullSegmentIsClean(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotTCPSend {
			return int64(a1)
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	body := []byte("GET / HTTP/1.0\r\n\r\n")
	n, err := c.Write(body)
	if err != nil || n != len(body) {
		t.Fatalf("Write = (%d,%v), want (%d,nil)", n, err, len(body))
	}
}

func TestConn_BoundIsEnforcedAcrossCloseDialCycles(t *testing.T) {
	// The one-socket bound is a PROCESS-WIDE invariant, exercised the way a
	// single-threaded app does: Dial/Close/Dial... ten times, with exactly one
	// live Conn at every step. (Dial and Close are NOT safe for concurrent
	// use — the kernel itself has one socket per process, so there is nothing
	// for a lock to protect beyond ClientLive; see the package doc.)
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	for i := 0; i < 10; i++ {
		c, err := Dial("10.0.2.2", 80)
		if err != nil {
			t.Fatalf("cycle %d: Dial = %v", i, err)
		}
		if _, err := Dial("10.0.2.2", 80); err != ErrConnBusy {
			t.Fatalf("cycle %d: second Dial = %v, want ErrConnBusy", i, err)
		}
		if err := c.Close(); err != nil {
			t.Fatalf("cycle %d: Close = %v", i, err)
		}
		if ClientLive != nil {
			t.Fatalf("cycle %d: ClientLive not cleared by Close", i)
		}
	}
}
