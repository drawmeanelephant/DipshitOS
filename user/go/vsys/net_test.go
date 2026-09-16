package vsys

import (
	"errors"
	"sync"
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
			if a0 == 1 && a1 == 1 {
				return 1 // readable
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
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSockReady {
			return -ErrETIMEDOUT // the kernel's bounded park expired
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	_, err := c.Read(make([]byte, 16))
	if !errors.Is(err, error(Errno(ErrETIMEDOUT))) {
		t.Fatalf("Read on a never-readable socket = %v, want Errno(ETIMEDOUT)", err)
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
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if sent != TCPPayloadMax || n != TCPPayloadMax {
		t.Fatalf("Write sent %d/%d bytes, want %d (payload_max)", sent, n, TCPPayloadMax)
	}
}

func TestConn_ConcurrentDialIsSerializedByTheBound(t *testing.T) {
	resetConn(t)
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 0 })
	var wg sync.WaitGroup
	var busy int
	var mu sync.Mutex
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := Dial("10.0.2.2", 80); err == ErrConnBusy {
				mu.Lock()
				busy++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if busy != 7 {
		t.Fatalf("busy refusals = %d, want 7 (one socket, 8 racers)", busy)
	}
}

func TestConn_SetReadDeadlineReachesTheKernel(t *testing.T) {
	resetConn(t)
	var got uintptr
	var seen bool
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSockReady {
			got = a2
			seen = true
			return -ErrETIMEDOUT
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	c.SetReadDeadline(1_500_000_000)
	if _, err := c.Read(make([]byte, 4)); !errors.Is(err, error(Errno(ErrETIMEDOUT))) {
		t.Fatalf("Read = %v, want Errno(ETIMEDOUT)", err)
	}
	if !seen || got != 1_500_000_000 {
		t.Fatalf("slot 76 timeout arg = %d (seen=%v), want 1500000000", got, seen)
	}
}

func TestConn_SetReadDeadlineNegativeIsUnbounded(t *testing.T) {
	resetConn(t)
	var got uintptr
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSockReady {
			got = a2
			return -ErrETIMEDOUT
		}
		return 0
	})
	c, _ := Dial("10.0.2.2", 80)
	c.SetReadDeadline(-5)
	_, _ = c.Read(make([]byte, 4))
	if got != 0 {
		t.Fatalf("negative deadline must map to 0 (unbounded), got %d", got)
	}
}
