package vsys

// Conn is a net.Conn-shaped single-socket connection over slots 30-33.
//
// THE BOUND (kernel law): VirelaiOS has exactly ONE TCP socket per process
// (kernel/src/tcp.zig is a process-wide singleton keyed by tcp.owner_pid).
// This type therefore allows one live Conn at a time: a second Dial while a
// Conn is open fails with ErrConnBusy, and Close-then-Dial is the legal
// reconnect path. Nothing here pretends otherwise.
type Conn struct {
	addr4  [4]byte
	port   uint16
	open   bool
	closed bool // peer FIN/RST observed: fail closed
	// readDeadlineNs bounds a blocking Read, in nanoseconds; it is converted
	// to a scheduler-TICK budget (1 tick ~ 1 s on this kernel) because the
	// kernel exposes no per-call clock to user space. 0 means "use
	// DefaultReadTicks". A peer that goes dark therefore makes the Read FAIL
	// CLOSED (ETIMEDOUT) instead of waiting forever.
	readDeadlineNs int64
}

// DefaultReadTicks is the bounded-wait ceiling used when no read deadline is
// set. An unbounded wait is deliberately not expressible: the point of this
// type is that a blocking Read can always fail closed.
const DefaultReadTicks = 30

// readTicks converts the deadline to a tick budget (>= 1).
func (c *Conn) readTicks() int {
	if c.readDeadlineNs <= 0 {
		return DefaultReadTicks
	}
	t := int(c.readDeadlineNs / 1_000_000_000)
	if t < 1 {
		t = 1
	}
	return t
}

// ParseIPv4 accepts a dotted-quad IPv4 literal ONLY. Hostnames are rejected
// with ErrNotIPLiteral: UDP DNS is out of scope for this runtime (the Zig TLS
// helper keeps owning the name-resolution path), so a silent failure is not
// acceptable.
func ParseIPv4(s string) ([4]byte, error) {
	var out [4]byte
	part := 0
	val := 0
	digits := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			val = val*10 + int(c-'0')
			digits++
			if val > 255 || digits > 3 {
				return out, ErrNotIPLiteral
			}
			continue
		}
		if c == '.' {
			if digits == 0 || part == 3 {
				return out, ErrNotIPLiteral
			}
			out[part] = byte(val)
			part++
			val, digits = 0, 0
			continue
		}
		return out, ErrNotIPLiteral // any letter/colon/space: not a literal
	}
	if part != 3 || digits == 0 {
		return out, ErrNotIPLiteral
	}
	out[3] = byte(val)
	return out, nil
}

// ipWord packs an IPv4 literal into the kernel's slot-30 argument word
// (big-endian in the low 32 bits).
func ipWord(a [4]byte) uintptr {
	return uintptr(uint32(a[0])<<24 | uint32(a[1])<<16 | uint32(a[2])<<8 | uint32(a[3]))
}

// ClientLive is the process's one live Conn (nil when none). It is the
// enforcement point for the one-socket bound.
var ClientLive *Conn

// Dial connects to an IPv4 literal and port. It refuses a second live Conn
// (ErrConnBusy) and a hostname (ErrNotIPLiteral) before touching the kernel.
func Dial(host string, port uint16) (*Conn, error) {
	if ClientLive != nil && ClientLive.open {
		return nil, ErrConnBusy
	}
	ip, err := ParseIPv4(host)
	if err != nil {
		return nil, err
	}
	if port == 0 {
		return nil, Errno(ErrEINVAL)
	}
	if _, err := syscallResult(syscallFn(SlotTCPConnect, ipWord(ip), uintptr(port), 0, 0)); err != nil {
		return nil, err
	}
	c := &Conn{addr4: ip, port: port, open: true}
	ClientLive = c
	return c, nil
}

// SetReadDeadline bounds a blocking Read, in nanoseconds, converted to a
// scheduler-tick budget (see Conn.readTicks). 0 selects DefaultReadTicks.
// A bounded read is what makes "the peer died mid-read" fail closed instead
// of waiting forever.
func (c *Conn) SetReadDeadline(ns int64) {
	if c == nil {
		return
	}
	if ns < 0 {
		ns = 0
	}
	c.readDeadlineNs = ns
}

// Read reads up to len(p) bytes. It BLOCKS by parking the goroutine through
// the kernel readiness seam (slot 76 op 1) rather than spinning: this is what
// removes the vi.TCPRecv-in-the-window-loop pattern. A peer FIN/RST makes it
// fail closed with ErrPeerClosed.
func (c *Conn) Read(p []byte) (int, error) {
	if c == nil || !c.open {
		return 0, ErrConnClosed
	}
	if c.closed {
		return 0, ErrPeerClosed
	}
	if len(p) == 0 {
		return 0, nil
	}
	max := len(p)
	if max > TCPPayloadMax {
		max = TCPPayloadMax
	}
	// Bounded wait. Slot 76 is a PROBE (the kernel refuses to re-enter the
	// scheduler inside a syscall handler), so the waiting lives HERE: each
	// iteration yields the M through sys_sleep, which is what lets the other
	// goroutine (the heartbeat) keep running while this Read is blocked.
	for i := 0; i < c.readTicks(); i++ {
		mask, err := c.probeReadable()
		if err != nil {
			return 0, err
		}
		if mask&1 != 0 {
			r, err := syscallResult(syscallFn(SlotTCPRecv, slicePtr(p[:max]), uintptr(max), 0, 0))
			if err != nil {
				return 0, err
			}
			if r == 0 {
				// Readable but empty: the peer is gone (FIN/RST consumed)
				// — fail closed instead of looping forever.
				c.closed = true
				return 0, ErrPeerClosed
			}
			return int(r), nil
		}
		// Yield one scheduler tick so other goroutines run. The M is not
		// blocked by this: sys_sleep is a scheduler point.
		if i+1 < c.readTicks() {
			syscallFn(SlotSleep, 1, 0, 0, 0)
		}
	}
	return 0, Errno(ErrETIMEDOUT)
}

// probeReadable asks the kernel for the socket's readiness mask (slot 76).
// A 0 mask means "nothing yet", not an error.
func (c *Conn) probeReadable() (int64, error) {
	r, err := syscallResult(syscallFn(SlotSockReady, 0, 1, 0, 0))
	if err != nil {
		if e, ok := err.(Errno); ok && int64(e) == ErrEAGAIN {
			return 0, ErrConnClosed // no socket owned any more
		}
		return 0, err
	}
	return r, nil
}

// Write sends p (one segment; the caller loops for a larger body). A write
// on a peer-closed Conn fails closed.
func (c *Conn) Write(p []byte) (int, error) {
	if c == nil || !c.open {
		return 0, ErrConnClosed
	}
	if c.closed {
		return 0, ErrPeerClosed
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > TCPPayloadMax {
		p = p[:TCPPayloadMax]
	}
	r, err := syscallResult(syscallFn(SlotTCPSend, slicePtr(p), uintptr(len(p)), 0, 0))
	if err != nil {
		return 0, err
	}
	return int(r), nil
}

// Close tears the connection down (FIN) and clears the process's live slot,
// so a later Dial is legal again.
func (c *Conn) Close() error {
	if c == nil || !c.open {
		return nil
	}
	c.open = false
	if ClientLive == c {
		ClientLive = nil
	}
	_, err := syscallResult(syscallFn(SlotTCPClose, 0, 0, 0, 0))
	return err
}
