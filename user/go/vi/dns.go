package vi

import "errors"

// DNS A-record resolution from Go (M67a, #1446) — zero kernel work.
//
// The kernel's own resolver (kernel/src/dns.zig) is an EL1 singleton the
// monitor drives (`net dns`); no syscall reaches it. This file therefore
// speaks RFC 1035 itself, over the UDP seam the N6 seam already exposes to
// EL0: slot 9 binds a listen port, slot 10 sends ONE datagram, slot 11
// copies the oldest datagram out (8-byte UDP header + payload). The seam's
// honest bounds shape everything below:
//
//   - payload_max is 64 (slot 10 clamps and would send the truncated
//     prefix — a corrupt query): a query that does not fit is REFUSED
//     before any syscall, never truncated into the wire.
//   - slot 10 sends from the FIXED source port 7000 (udp.default_src_port),
//     so the reply lands on 7000 and the client must be listening BEFORE
//     the query goes out — an unbound port drops the datagram.
//   - slot 10 does NOT resolve ARP (.no_peer → EINVAL): resolve-then-retry
//     stays the CALLER's contract. ErrDNSRefused surfaces that send refusal;
//     this client never retries it behind the caller's back.
//   - there is no unlisten slot and no per-port ownership: listening twice
//     (EINVAL) is treated as "already bound" and recv(port) works for any
//     task, so a second ResolveDNS in one process is legal and a reply can
//     in principle be consumed by a peer task. Documented bound, not hidden.

const (
	// DNSPort is the well-known resolver port the query is sent to.
	DNSPort = 53
	// udpSourcePort is udp.default_src_port: slot 10 always sends from
	// here, so it is also the port the reply arrives on.
	udpSourcePort = 7000
	// udpPayloadMax is udp.payload_max: the largest datagram payload the
	// seam copies out or in.
	udpPayloadMax = 64
	// udpDatagramMax is udp.datagram_max: payload + the 8-byte UDP header
	// the recv seam returns.
	udpDatagramMax = 72
	// DefaultDNSBudgetNs bounds one resolution. A resolution that outlives
	// its budget fails closed (ETIMEDOUT), never blocks forever.
	DefaultDNSBudgetNs = 30_000_000_000
)

// DefaultDNSServer is the reference VM's resolver: the host gateway the
// runner's --net-dns-respond answers on. The kernel keeps no DHCP-learned
// server, so a program with a different resolver re-points this.
var DefaultDNSServer = [4]byte{10, 0, 0, 2}

// DNS-domain failures. They are userland protocol conditions, not kernel
// errnos — distinct sentinels so a caller can branch on what happened.
var (
	// ErrNameTooLong: the encoded query would not fit one datagram
	// (udpPayloadMax). Refused before any syscall.
	ErrNameTooLong = errString("dns: name does not fit one UDP datagram")
	// ErrNameNotFound: the server answered NXDOMAIN (rcode 3).
	ErrNameNotFound = errString("dns: name not found (NXDOMAIN)")
	// ErrDNSFailed: any other rcode, a malformed/truncated reply, or a
	// response with no A record.
	ErrDNSFailed = errString("dns: resolution failed")
	// ErrDNSRefused: the transport refused the send (EINVAL — the seam's
	// .no_peer/.not_ready mapping, usually the server's MAC missing from
	// ARP). The caller resolves (monitor `net arp <ip>`) and retries.
	ErrDNSRefused = errString("dns: send refused — resolve the peer first, then retry")
)

// errNotOurs marks a received datagram that is not our reply (wrong source
// port, wrong ID, not a response): consumed, and the poll keeps going.
var errNotOurs = errors.New("dns: not our reply")

// dnsPortBound records that this process already bound udpSourcePort (the
// listen slot has no unlisten; a repeat bind would fail EINVAL honestly).
var dnsPortBound bool

// UDPListen binds port in the kernel's global listen table (slot 9).
func UDPListen(port uint16) int64 { return svc1(SlotUDPListen, uintptr(port)) }

// UDPSend sends ONE datagram to ip:port from the fixed source port (slot
// 10). Returns the payload length sent, or a negative errno. len is capped
// at udpPayloadMax by the kernel — this wrapper refuses more up front so
// truncation can never masquerade as a send.
func UDPSend(ip [4]byte, port uint16, b []byte) int64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) > udpPayloadMax {
		return -ErrEINVAL
	}
	return svc4(SlotUDPSend, ipv4Word(ip), uintptr(port), bytePtr(b), uintptr(len(b)))
}

// udpRecv copies the oldest datagram for the listener on port OUT (slot
// 11): the full 8-byte UDP header + payload, clamped to udpDatagramMax.
// Returns the copied length (0 = ring empty) or a negative errno.
func UDPRecv(port uint16, buf []byte) int64 {
	if len(buf) == 0 {
		return 0
	}
	return svc3(SlotUDPRecv, uintptr(port), bytePtr(buf), uintptr(min(len(buf), udpDatagramMax)))
}

// ResolveDNS resolves name to its first IPv4 A record via server, over the
// UDP seam. budgetNs <= 0 means DefaultDNSBudgetNs. The wait is the same
// blocking-with-poll shape as Conn.Recv: probe the ring, check the
// deadline, park one scheduler tick, repeat — other goroutines keep running
// while this task is parked (the M65 pacing).
//
// A send refusal (ErrDNSRefused) is NOT retried: per the N6 seam the
// caller resolves the peer (monitor `net arp <server>`) and retries.
func ResolveDNS(name string, server [4]byte, budgetNs int64) ([4]byte, error) {
	query, id, err := buildDNSQuery(name)
	if err != nil {
		return [4]byte{}, err
	}

	// Bind the reply port BEFORE the query goes out: the reply targets the
	// fixed source port, and a datagram for an unbound port is dropped.
	// EINVAL here means the port is already bound (no unlisten exists, and
	// recv has no ownership check) — that is this process's earlier
	// resolution or another task's, and recv(port) works either way.
	if !dnsPortBound {
		if rc := UDPListen(udpSourcePort); rc == 0 {
			dnsPortBound = true
		}
	}

	// One query, honestly refused or honestly sent.
	if rc := UDPSend(server, DNSPort, query); rc < 0 {
		if -rc == ErrEINVAL {
			return [4]byte{}, ErrDNSRefused
		}
		return [4]byte{}, errno(-rc)
	}

	if budgetNs <= 0 {
		budgetNs = DefaultDNSBudgetNs
	}
	deadline := Nanos() + budgetNs
	buf := make([]byte, udpDatagramMax)
	for polls := 0; ; polls++ {
		n := UDPRecv(udpSourcePort, buf)
		if n < 0 {
			// Not "empty" (that is 0): the port is not bound (the table
			// filled between listen and recv) — fail honestly.
			return [4]byte{}, errno(-n)
		}
		if n > 0 {
			ip, perr := parseDNSReply(buf[:n], id)
			switch {
			case perr == nil:
				return ip, nil
			case errors.Is(perr, errNotOurs):
				// Not our reply (a stray datagram on the shared port): it
				// was consumed, keep waiting.
			default:
				return [4]byte{}, perr
			}
		}
		if Nanos() >= deadline || polls >= maxRecvPolls {
			return [4]byte{}, errno(ErrETIMEDOUT)
		}
		svc1(SlotSleep, 1)
	}
}

// dnsIDSeq turns over on every query: a fast retry must not reuse the ID
// the clock alone would hand it (two Nanos() reads can land in the same
// tick), so the counter is mixed into the low bits.
var dnsIDSeq uint32

// buildDNSQuery encodes an RFC 1035 A-record query for name. The query
// must fit ONE datagram (header + QNAME + QTYPE/QCLASS <= udpPayloadMax) —
// anything longer is refused, never truncated onto the wire. The reply
// must echo the ID.
func buildDNSQuery(name string) ([]byte, uint16, error) {
	if name == "" {
		return nil, 0, ErrNameTooLong
	}
	qname := make([]byte, 0, len(name)+2)
	start := 0
	for i := 0; i <= len(name); i++ {
		if i == len(name) || name[i] == '.' {
			label := name[start:i]
			if len(label) == 0 || len(label) > 63 {
				return nil, 0, ErrNameTooLong
			}
			qname = append(qname, byte(len(label)))
			qname = append(qname, label...)
			start = i + 1
		}
	}
	qname = append(qname, 0)
	if 12+len(qname)+4 > udpPayloadMax {
		return nil, 0, ErrNameTooLong
	}

	dnsIDSeq++
	id := uint16(Nanos()) ^ uint16(dnsIDSeq)
	query := make([]byte, 0, 12+len(qname)+4)
	query = append(query, byte(id>>8), byte(id))
	query = append(query, 0x01, 0x00)                         // flags: RD (recursion desired)
	query = append(query, 0x00, 0x01)                         // QDCOUNT = 1
	query = append(query, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00) // AN/NS/AR = 0
	query = append(query, qname...)
	query = append(query, 0x00, 0x01) // QTYPE = A
	query = append(query, 0x00, 0x01) // QCLASS = IN
	return query, id, nil
}

// parseDNSReply parses one received datagram (8-byte UDP header + DNS
// message) and extracts the first A record whose message echoes id.
// errNotOurs marks a datagram that is not our reply (too short, wrong
// source port, wrong ID, not a response) — the caller consumes it and
// keeps waiting. A genuine failure (rcode, TC, truncation, no A record)
// is an error.
func parseDNSReply(dgram []byte, id uint16) (ip [4]byte, err error) {
	if len(dgram) < 8+12 {
		// Shorter than a UDP header + DNS header: not a DNS reply at all.
		return ip, errNotOurs
	}
	srcPort := uint16(dgram[0])<<8 | uint16(dgram[1])
	if srcPort != DNSPort {
		return ip, errNotOurs
	}
	msg := dgram[8:]
	if uint16(msg[0])<<8|uint16(msg[1]) != id {
		return ip, errNotOurs
	}
	flags := uint16(msg[2])<<8 | uint16(msg[3])
	if flags&0x8000 == 0 {
		return ip, errNotOurs // QR = 0: a query, not a response
	}
	if flags&0x0200 != 0 {
		// TC = 1: the server's reply did not fit its transport, and the
		// kernel clamps the datagram at 72 bytes anyway — what we hold may
		// be missing records. Refusing is honest; guessing is not.
		return ip, ErrDNSFailed
	}
	switch rcode := int(flags & 0x000F); rcode {
	case 0:
	case 3:
		return ip, ErrNameNotFound
	default:
		return ip, ErrDNSFailed
	}

	qdcount := int(uint16(msg[4])<<8 | uint16(msg[5]))
	ancount := int(uint16(msg[6])<<8 | uint16(msg[7]))
	off := 12
	for i := 0; i < qdcount; i++ {
		if off, err = dnsSkipName(msg, off); err != nil {
			return ip, err
		}
		off += 4 // QTYPE + QCLASS
		if off > len(msg) {
			return ip, ErrDNSFailed
		}
	}
	// Walk EVERY answer the header claims: a message whose answer section
	// runs past the bytes we actually received has lied about its own
	// section (or the kernel clamped it) — refuse whole, never trust a
	// record that happens to sit inside the prefix.
	var firstA [4]byte
	haveA := false
	for i := 0; i < ancount; i++ {
		if off, err = dnsSkipName(msg, off); err != nil {
			return ip, err
		}
		if off+10 > len(msg) {
			return ip, ErrDNSFailed // TYPE(2) CLASS(2) TTL(4) RDLENGTH(2)
		}
		rectype := uint16(msg[off])<<8 | uint16(msg[off+1])
		rdlen := int(uint16(msg[off+8])<<8 | uint16(msg[off+9]))
		off += 10
		if rectype == 1 && rdlen == 4 {
			if off+4 > len(msg) {
				return ip, ErrDNSFailed
			}
			if !haveA {
				firstA = [4]byte{msg[off], msg[off+1], msg[off+2], msg[off+3]}
				haveA = true
			}
		}
		off += rdlen // not an A record (e.g. CNAME): skip it
	}
	if !haveA {
		return ip, ErrDNSFailed // answered, but no A record
	}
	return firstA, nil
}

// dnsSkipName walks one (possibly compressed) name: a compression pointer
// consumes two bytes, real labels walk to the zero terminator.
func dnsSkipName(msg []byte, off int) (int, error) {
	for {
		if off >= len(msg) {
			return off, ErrDNSFailed
		}
		b := int(msg[off])
		if b == 0 {
			return off + 1, nil
		}
		if b&0xC0 == 0xC0 {
			if off+2 > len(msg) {
				return off, ErrDNSFailed
			}
			return off + 2, nil
		}
		if b&0xC0 != 0 {
			return off, ErrDNSFailed // unsupported label kind
		}
		off += 1 + b
	}
}
