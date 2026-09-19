// The guest-facing TLS surface: Dial connects over the M67a socket seam
// (vi.Dial — kernel TCP slots 30-33, DNS in front of the dial), completes
// the ADR 0029 TLS 1.3 handshake in-process, and hands back a Read/Write/
// Close connection. This is the card M67b's whole point: HTTPS without
// execing FETCHS.BIN — no spawn, no helper process, no argv caps.

package tls

import "virelai/vi"

// viTransport bridges vi.Conn to the client's transport. One goroutine owns
// the traffic, the same contract vi.Conn states.
type viTransport struct {
	conn *vi.Conn
}

func (t *viTransport) read(p []byte) (int, error) {
	// Recv is blocking-with-poll with the bounded default budget: a peer
	// that goes dark fails closed instead of parking forever.
	return t.conn.Recv(p)
}

func (t *viTransport) write(p []byte) (int, error) {
	n, err := t.conn.Send(p)
	if err != nil {
		return 0, err
	}
	if n != len(p) {
		// Send advances only by confirmed counts and returns nil error only
		// when the whole buffer was accepted.
		return 0, errTransport
	}
	return n, nil
}

func (t *viTransport) close() error { return t.conn.Close() }

// TLSConn is an established TLS 1.3 connection.
type TLSConn struct {
	cl   *client
	conn *vi.Conn
}

// Dial connects to addr:port and handshakes. serverName is what goes into
// the SNI extension and what the certificate is verified against — it may
// differ from the dial address (the live gate dials 10.0.0.2 as
// leaf.example.com). An empty serverName verifies against the dial address.
// The validity clock is vi.Time and the entropy source is the kernel CSPRNG
// (slot 72), the same contract FETCHS.BIN had.
func Dial(addr string, port uint16, serverName string) (*TLSConn, error) {
	conn, err := vi.Dial(addr, port)
	if err != nil {
		return nil, err
	}
	if serverName == "" {
		serverName = addr
	}
	c := &TLSConn{conn: conn}
	c.cl = newClient(&viTransport{conn: conn}, serverName, vi.Time(), viRandom, true)
	if err := c.cl.handshake(); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return c, nil
}

// viRandom fills p from the kernel CSPRNG (slot 72 getrandom, 256 bytes per
// call — loop for more).
func viRandom(p []byte) error {
	for len(p) > 0 {
		take := len(p)
		if take > 256 {
			take = 256
		}
		n, err := vi.Random(p[:take])
		if err != nil {
			return err
		}
		if n <= 0 {
			return ErrEntropyFailed
		}
		p = p[n:]
	}
	return nil
}

// Write sends data as one or more AEAD records (chunked to the 2^14 record
// limit), advancing only by confirmed sends.
func (c *TLSConn) Write(p []byte) (int, error) {
	sent := 0
	for sent < len(p) {
		take := len(p) - sent
		if take > maxPlaintext {
			take = maxPlaintext
		}
		if err := c.cl.write(p[sent : sent+take]); err != nil {
			return sent, err
		}
		sent += take
	}
	return sent, nil
}

// Read returns application data.
func (c *TLSConn) Read(p []byte) (int, error) {
	return c.cl.read(p)
}

// Close sends close_notify and tears the TCP connection down.
func (c *TLSConn) Close() error { return c.cl.close() }

// LastValidation reports the chain-validation verdict for troubleshooting.
func (c *TLSConn) LastValidation() validationResult { return c.cl.lastValidation }
