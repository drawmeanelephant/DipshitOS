package vi

import (
	"errors"
	"testing"
	"unsafe"
)

// hookBytes rebuilds a byte argument the fake kernel received. The pointer
// is the one bytePtr handed the seam (still live inside the call), so this
// is the same contract the guest assembly reads through — test-only.
func hookBytes(a0, a1 uintptr) []byte {
	if a0 == 0 || a1 == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
}

// The DNS host fake: a scripted kernel that counts the seam calls, captures
// the query, and answers from a caller-provided script (the same inject-a-
// fake-kernel contract the file surface's tests use through
// SetSyscallHookForTest).
type dnsFake struct {
	listenCalls int
	sendCalls   int
	recvCalls   int
	sleeps      int
	other       int
	listenPort  uintptr
	sentIP      uint32
	sentPort    uintptr
	sentQuery   []byte
	// now stamps every seam event with a sequence number so a test can pin
	// ORDER (e.g. the reply port is bound before the query goes out), not
	// just counts.
	listenSeq int
	sendSeq   int
	recvSeq   int
	now       int
	// recvScript maps the 1-based recv call to the datagram to deliver (nil
	// = empty ring, rc 0). A nil script always returns 0.
	recvScript func(call int) []byte
}

func (f *dnsFake) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case SlotUDPListen:
		f.listenCalls++
		f.listenPort = a0
		f.now++
		f.listenSeq = f.now
		return 0
	case SlotUDPSend:
		f.sendCalls++
		f.sentIP = uint32(a0)
		f.sentPort = a1
		f.sentQuery = hookBytes(a2, a3)
		f.now++
		f.sendSeq = f.now
		return int64(a3)
	case SlotUDPRecv:
		f.recvCalls++
		f.now++
		f.recvSeq = f.now
		if f.recvScript == nil {
			return 0
		}
		dgram := f.recvScript(f.recvCalls)
		if dgram == nil {
			return 0
		}
		// Slot 11 args: (port, buf, max) — the buffer is a1, clamped by a2.
		take := len(dgram)
		if uintptr(take) > a2 {
			take = int(a2)
		}
		copy(hookBytes(a1, uintptr(take)), dgram[:take])
		return int64(take)
	case SlotSleep:
		f.sleeps++
		return 0
	}
	f.other++
	return -ErrENOSYS
}

func startDNSFake(t *testing.T) *dnsFake {
	t.Helper()
	f := &dnsFake{}
	prev := SetSyscallHookForTest(f.hook)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	t.Cleanup(func() { dnsPortBound = false })
	return f
}

// udpDgram wraps a DNS message in the 8-byte UDP header slot 11 returns
// (src port first — the field the client filters on).
func udpDgram(srcPort uint16, msg []byte) []byte {
	d := make([]byte, 8+len(msg))
	d[0] = byte(srcPort >> 8)
	d[1] = byte(srcPort)
	d[2] = byte(udpSourcePort >> 8)
	d[3] = byte(udpSourcePort & 0xff)
	n := 8 + len(msg)
	d[4] = byte(n >> 8)
	d[5] = byte(n)
	copy(d[8:], msg)
	return d
}

// dnsReplyFor mirrors the runner's buildDnsReply (host/vm-runner): echoed
// question, one answer with a compression pointer to offset 12, one A
// record. The reply echoes the query's ID.
func dnsReplyFor(query []byte, ip [4]byte) []byte {
	msg := make([]byte, 0, len(query)+16)
	msg = append(msg, query[0], query[1], 0x81, 0x80,
		0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)
	msg = append(msg, query[12:]...) // the echoed question
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, ip[0], ip[1], ip[2], ip[3])
	return msg
}

func TestResolveDNS_QueryFraming(t *testing.T) {
	f := startDNSFake(t)
	f.recvScript = func(int) []byte {
		return udpDgram(DNSPort, dnsReplyFor(f.sentQuery, [4]byte{93, 184, 216, 34}))
	}
	ip, err := ResolveDNS("myhost.local", [4]byte{10, 0, 0, 2}, 0)
	if err != nil {
		t.Fatalf("ResolveDNS: %v", err)
	}
	if ip != [4]byte{93, 184, 216, 34} {
		t.Fatalf("resolved %v, want 93.184.216.34", ip)
	}
	// The reply port is bound BEFORE the query goes out: an unbound port
	// drops the datagram, so listen-then-send is the only legal order —
	// pinned by sequence, not just by counts (a send-before-listen would
	// still leave listenCalls == 1).
	if f.listenCalls != 1 || f.listenPort != udpSourcePort {
		t.Fatalf("listen = %d calls on port %d, want 1 call on %d",
			f.listenCalls, f.listenPort, udpSourcePort)
	}
	if f.listenSeq == 0 || f.sendSeq == 0 || f.listenSeq >= f.sendSeq {
		t.Fatalf("event order = listen#%d, send#%d, want listen before send",
			f.listenSeq, f.sendSeq)
	}
	if f.sentIP != 0x0a000002 || f.sentPort != DNSPort {
		t.Fatalf("send = %08x:%d, want 0a000002:53", f.sentIP, f.sentPort)
	}
	if len(f.sentQuery) > udpPayloadMax {
		t.Fatalf("query is %d bytes, bound is %d", len(f.sentQuery), udpPayloadMax)
	}
	// Header: the captured ID, RD set, one question.
	if f.sentQuery[2] != 0x01 || f.sentQuery[3] != 0x00 {
		t.Fatalf("query flags = %02x%02x, want RD (0x0100)", f.sentQuery[2], f.sentQuery[3])
	}
	if f.sentQuery[4] != 0 || f.sentQuery[5] != 1 {
		t.Fatalf("QDCOUNT = %d, want 1", uint16(f.sentQuery[4])<<8|uint16(f.sentQuery[5]))
	}
	// QNAME for myhost.local: \x06myhost\x05local\x00, then A/IN.
	qname := []byte{6, 'm', 'y', 'h', 'o', 's', 't', 5, 'l', 'o', 'c', 'a', 'l', 0}
	want := append([]byte{f.sentQuery[0], f.sentQuery[1], 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}, qname...)
	want = append(want, 0x00, 0x01, 0x00, 0x01)
	if string(f.sentQuery) != string(want) {
		t.Fatalf("query = % x, want % x", f.sentQuery, want)
	}
}

func TestResolveDNS_LongNameRefusedBeforeSyscall(t *testing.T) {
	f := startDNSFake(t)
	// 7 labels of 8 bytes: the encoded query alone blows the 64-byte
	// datagram bound. The kernel would truncate it into a corrupt query —
	// so the client must refuse before ANY syscall.
	name := ""
	for i := 0; i < 7; i++ {
		if i > 0 {
			name += "."
		}
		name += "abcdefgh"
	}
	if _, err := ResolveDNS(name, DefaultDNSServer, 0); !errors.Is(err, ErrNameTooLong) {
		t.Fatalf("ResolveDNS(long) = %v, want ErrNameTooLong", err)
	}
	if f.listenCalls != 0 || f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("refused resolve touched the seam: listen=%d send=%d recv=%d",
			f.listenCalls, f.sendCalls, f.recvCalls)
	}
}

func TestResolveDNS_SendRefusedIsNotRetried(t *testing.T) {
	// The N6 seam refuses the send (EINVAL: .no_peer — the server's MAC is
	// not in ARP) and resolves nothing itself. Resolve-then-retry stays the
	// CALLER's contract: one send, no recv, an honest error.
	sendCalls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotUDPListen:
			return 0
		case SlotUDPSend:
			sendCalls++
			return -ErrEINVAL
		}
		t.Fatalf("unexpected slot %d after a refused send", num)
		return -ErrENOSYS
	})
	defer SetSyscallHookForTest(prev)
	t.Cleanup(func() { dnsPortBound = false })

	_, err := ResolveDNS("myhost.local", DefaultDNSServer, 0)
	if !errors.Is(err, ErrDNSRefused) {
		t.Fatalf("ResolveDNS with a refused send = %v, want ErrDNSRefused", err)
	}
	if sendCalls != 1 {
		t.Fatalf("send calls = %d, want exactly one — the retry is the caller's", sendCalls)
	}
}

func TestResolveDNS_NXDOMAIN(t *testing.T) {
	f := startDNSFake(t)
	f.recvScript = func(int) []byte {
		r := dnsReplyFor(f.sentQuery, [4]byte{1, 2, 3, 4})
		r[3] = 0x83 // RCODE 3 in the low nibble of the second flags byte
		return udpDgram(DNSPort, r)
	}
	if _, err := ResolveDNS("nosuch.name", DefaultDNSServer, 0); !errors.Is(err, ErrNameNotFound) {
		t.Fatalf("NXDOMAIN = %v, want ErrNameNotFound", err)
	}
}

func TestResolveDNS_TimeoutFailsClosed(t *testing.T) {
	// A server that never answers must fail closed on the wall-clock
	// budget — after PARKING between polls (the M65 pacing), never spinning.
	f := startDNSFake(t)
	_, err := ResolveDNS("myhost.local", DefaultDNSServer, 2_000_000) // 2 ms
	if !errors.Is(err, error(errno(ErrETIMEDOUT))) {
		t.Fatalf("unanswered resolve = %v, want Errno(ETIMEDOUT)", err)
	}
	if f.sleeps == 0 {
		t.Fatal("the wait must park between polls, not spin")
	}
	if f.recvCalls < 2 {
		t.Fatalf("recv polled %d times over the budget, want several", f.recvCalls)
	}
}

func TestResolveDNS_SecondCallDoesNotRelisten(t *testing.T) {
	// The listen slot has no unlisten: a second bind would fail EINVAL, so
	// the client binds once per process and reuses the port.
	f := startDNSFake(t)
	f.recvScript = func(int) []byte {
		return udpDgram(DNSPort, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	if _, err := ResolveDNS("a.first", DefaultDNSServer, 0); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	if _, err := ResolveDNS("b.second", DefaultDNSServer, 0); err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if f.listenCalls != 1 {
		t.Fatalf("listen called %d times, want once per process", f.listenCalls)
	}
}

func TestResolveDNS_SkipsStrayThenAnswers(t *testing.T) {
	// recv has no per-port ownership: another task's datagram can land on
	// the shared port. A datagram that is not our reply (wrong source port
	// here) is consumed and the poll continues.
	f := startDNSFake(t)
	f.recvScript = func(call int) []byte {
		if call == 1 {
			return udpDgram(9999, []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
		}
		return udpDgram(DNSPort, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	ip, err := ResolveDNS("myhost.local", DefaultDNSServer, 0)
	if err != nil || ip != [4]byte{10, 0, 0, 2} {
		t.Fatalf("resolve after a stray = (%v, %v), want 10.0.0.2", ip, err)
	}
	if f.recvCalls != 2 {
		t.Fatalf("recv calls = %d, want 2 (stray then answer)", f.recvCalls)
	}
}

func TestParseDNSReply_MalformedAndUnanswered(t *testing.T) {
	query, id, err := buildDNSQuery("myhost.local")
	if err != nil {
		t.Fatalf("buildDNSQuery: %v", err)
	}
	full := dnsReplyFor(query, [4]byte{10, 0, 0, 2})

	// An answer cut short by the datagram bound is refused, not parsed as
	// a zero address.
	truncated := append([]byte(nil), full[:len(full)-2]...)
	if _, err := parseDNSReply(udpDgram(DNSPort, truncated), id); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("truncated reply = %v, want ErrDNSFailed", err)
	}
	// A response with no A record is an honest failure.
	noAnswer := append([]byte(nil), full[:12+len(query)-12]...)
	noAnswer[6], noAnswer[7] = 0x00, 0x00 // ANCOUNT = 0
	if _, err := parseDNSReply(udpDgram(DNSPort, noAnswer), id); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("empty answer = %v, want ErrDNSFailed", err)
	}
	// A query (QR = 0) is not our reply: not an error, keep waiting.
	if _, err := parseDNSReply(udpDgram(DNSPort, query), id); !errors.Is(err, errNotOurs) {
		t.Fatalf("a query echoed back = %v, want errNotOurs", err)
	}
	// A different ID is not our reply.
	if _, err := parseDNSReply(udpDgram(DNSPort, full), id+1); !errors.Is(err, errNotOurs) {
		t.Fatalf("mismatched ID = %v, want errNotOurs", err)
	}
}

func TestParseDNSReply_HostileVectors(t *testing.T) {
	query, id, err := buildDNSQuery("myhost.local")
	if err != nil {
		t.Fatalf("buildDNSQuery: %v", err)
	}
	full := dnsReplyFor(query, [4]byte{10, 0, 0, 2})

	// SERVFAIL (2) and REFUSED (5) are honest failures, never a zero IP.
	for _, rcode := range []byte{2, 5} {
		r := append([]byte(nil), full...)
		r[3] = 0x80 | rcode
		if _, err := parseDNSReply(udpDgram(DNSPort, r), id); !errors.Is(err, ErrDNSFailed) {
			t.Fatalf("rcode %d = %v, want ErrDNSFailed", rcode, err)
		}
	}
	// TC = 1: the reply was cut off in transit — refuse, never guess.
	tc := append([]byte(nil), full...)
	tc[2] |= 0x02
	if _, err := parseDNSReply(udpDgram(DNSPort, tc), id); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("TC=1 = %v, want ErrDNSFailed", err)
	}
	// A host claiming 65535 answers runs off the copied datagram: the
	// bounds check fires before any record is trusted.
	many := append([]byte(nil), full[:12]...)
	many = append(many, query[12:]...) // the echoed question
	many[6], many[7] = 0xff, 0xff      // ANCOUNT = 65535
	many = append(many, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0, 0, 1, 0x2C, 0, 4, 1, 2, 3, 4)
	if _, err := parseDNSReply(udpDgram(DNSPort, many), id); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("ANCOUNT=65535 = %v, want ErrDNSFailed", err)
	}
	// A compression pointer that points at ITSELF: the walker skips two
	// bytes without following it, so the parse terminates.
	selfPtr := append([]byte(nil), full[:12]...)
	selfPtr = append(selfPtr, query[12:]...)
	selfPtr[6], selfPtr[7] = 0x00, 0x01   // ANCOUNT = 1
	selfPtr = append(selfPtr, 0xC0, 0x0C, // a name pointer at offset 12: itself
		0x00, 0x01, 0x00, 0x01, 0, 0, 1, 0x2C, 0, 4, 1, 2, 3, 4)
	ip, err := parseDNSReply(udpDgram(DNSPort, selfPtr), id)
	if err != nil || ip != [4]byte{1, 2, 3, 4} {
		t.Fatalf("self-pointer name = (%v, %v), want 1.2.3.4 with no error", ip, err)
	}
	// A datagram too short to hold a DNS header is a stray, not a failure.
	if _, err := parseDNSReply(udpDgram(DNSPort, []byte{0, 1, 2, 3, 4, 5}), id); !errors.Is(err, errNotOurs) {
		t.Fatalf("short datagram = %v, want errNotOurs", err)
	}
}
