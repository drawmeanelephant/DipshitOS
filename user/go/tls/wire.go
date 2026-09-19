// The bounds-checked wire reader for TLS handshake bodies (the Go mirror of
// handshake.zig's Reader): vectors with u8/u16/u24 length prefixes, every
// overrun an error, never a panic.

package tls

type wireReader struct {
	buf []byte
	pos int
}

func newWireReader(buf []byte) wireReader { return wireReader{buf: buf} }

func (r *wireReader) atEnd() bool { return r.pos >= len(r.buf) }

func (r *wireReader) take(n int) ([]byte, error) {
	if r.pos+n > len(r.buf) || n < 0 {
		return nil, errDER
	}
	out := r.buf[r.pos : r.pos+n]
	r.pos += n
	return out, nil
}

func (r *wireReader) u8() (byte, error) {
	b, err := r.take(1)
	if err != nil {
		return 0, err
	}
	return b[0], nil
}

func (r *wireReader) u16() (uint16, error) {
	b, err := r.take(2)
	if err != nil {
		return 0, err
	}
	return uint16(b[0])<<8 | uint16(b[1]), nil
}

func (r *wireReader) vec8() ([]byte, error) {
	n, err := r.u8()
	if err != nil {
		return nil, err
	}
	return r.take(int(n))
}

func (r *wireReader) vec16() ([]byte, error) {
	n, err := r.u16()
	if err != nil {
		return nil, err
	}
	return r.take(int(n))
}

func (r *wireReader) vec24() ([]byte, error) {
	b, err := r.take(3)
	if err != nil {
		return nil, err
	}
	n := int(b[0])<<16 | int(b[1])<<8 | int(b[2])
	return r.take(n)
}
