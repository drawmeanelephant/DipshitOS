package main

// Git pkt-line (gitprotocol.txt): a 4-byte lowercase hex length prefix
// that includes itself, then payload. 0000 is flush. 0001 is delimiter.

type pktErr string

func (e pktErr) Error() string { return string(e) }

var (
	errPktShort = pktErr("pkt-line: truncated")
	errPktLen   = pktErr("pkt-line: bad length")
	errPktHuge  = pktErr("pkt-line: length past 65520")
)

const pktMax = 65520

type pkt struct {
	Flush bool
	Delim bool
	Data  []byte
}

func pktEncode(data []byte) []byte {
	n := len(data) + 4
	out := make([]byte, 4+len(data))
	putHex4(out, n)
	copy(out[4:], data)
	return out
}

func pktFlush() []byte { return []byte("0000") }

func pktEncodeString(s string) []byte { return pktEncode([]byte(s)) }

func putHex4(b []byte, n int) {
	for i := 3; i >= 0; i-- {
		d := n & 0xf
		if d < 10 {
			b[i] = byte('0' + d)
		} else {
			b[i] = byte('a' + d - 10)
		}
		n >>= 4
	}
}

func parseHex4(b []byte) (int, bool) {
	if len(b) < 4 {
		return 0, false
	}
	n := 0
	for i := 0; i < 4; i++ {
		v, ok := fromHex(b[i])
		if !ok {
			return 0, false
		}
		n = n<<4 | int(v)
	}
	return n, true
}

// pktRead pulls one packet from b. rest is the unconsumed tail.
func pktRead(b []byte) (pkt, []byte, error) {
	if len(b) < 4 {
		return pkt{}, b, errPktShort
	}
	n, ok := parseHex4(b[:4])
	if !ok {
		return pkt{}, b, errPktLen
	}
	if n == 0 {
		return pkt{Flush: true}, b[4:], nil
	}
	if n == 1 {
		return pkt{Delim: true}, b[4:], nil
	}
	if n < 4 || n > pktMax {
		return pkt{}, b, errPktLen
	}
	if len(b) < n {
		return pkt{}, b, errPktShort
	}
	return pkt{Data: b[4:n]}, b[n:], nil
}

// pktSplit walks a pkt-line stream until a flush or the buffer ends.
// leftover is unframed bytes after the last packet (a raw packfile tail).
func pktSplit(b []byte) (pkts []pkt, leftover []byte, err error) {
	for len(b) >= 4 {
		p, rest, e := pktRead(b)
		if e != nil {
			// Not a pkt-line: treat as leftover (upload-pack pack tail).
			if e == errPktLen || e == errPktShort {
				return pkts, b, nil
			}
			return pkts, b, e
		}
		pkts = append(pkts, p)
		b = rest
		if p.Flush {
			return pkts, b, nil
		}
	}
	return pkts, b, nil
}
