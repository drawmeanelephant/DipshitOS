package main

// SHA-1 (FIPS 180-4) for git object IDs. crypto/sha1 is not imported: the
// GOOS=virelai stdlib does not carry fmt/os, and this keeps hashing inside
// the git client rather than a TLS port (ADR 0029 / 0030: no Go crypto for
// the HTTPS hop).

func rotl32(x uint32, n uint) uint32 {
	return x<<n | x>>(32-n)
}

func putBE32(b []byte, v uint32) {
	b[0] = byte(v >> 24)
	b[1] = byte(v >> 16)
	b[2] = byte(v >> 8)
	b[3] = byte(v)
}

func sha1Sum(msg []byte) [20]byte {
	h0 := uint32(0x67452301)
	h1 := uint32(0xEFCDAB89)
	h2 := uint32(0x98BADCFE)
	h3 := uint32(0x10325476)
	h4 := uint32(0xC3D2E1F0)

	ml := uint64(len(msg)) * 8
	padded := make([]byte, len(msg), len(msg)+72)
	copy(padded, msg)
	padded = append(padded, 0x80)
	for (len(padded)+8)%64 != 0 {
		padded = append(padded, 0)
	}
	var lenb [8]byte
	for i := 0; i < 8; i++ {
		lenb[7-i] = byte(ml >> (8 * uint(i)))
	}
	padded = append(padded, lenb[:]...)

	for chunk := 0; chunk < len(padded); chunk += 64 {
		var w [80]uint32
		for i := 0; i < 16; i++ {
			off := chunk + i*4
			w[i] = uint32(padded[off])<<24 | uint32(padded[off+1])<<16 | uint32(padded[off+2])<<8 | uint32(padded[off+3])
		}
		for i := 16; i < 80; i++ {
			w[i] = rotl32(w[i-3]^w[i-8]^w[i-14]^w[i-16], 1)
		}
		a, b, c, d, e := h0, h1, h2, h3, h4
		for i := 0; i < 80; i++ {
			var f, k uint32
			switch {
			case i < 20:
				f = (b & c) | (^b & d)
				k = 0x5A827999
			case i < 40:
				f = b ^ c ^ d
				k = 0x6ED9EBA1
			case i < 60:
				f = (b & c) | (b & d) | (c & d)
				k = 0x8F1BBCDC
			default:
				f = b ^ c ^ d
				k = 0xCA62C1D6
			}
			temp := rotl32(a, 5) + f + e + k + w[i]
			e = d
			d = c
			c = rotl32(b, 30)
			b = a
			a = temp
		}
		h0 += a
		h1 += b
		h2 += c
		h3 += d
		h4 += e
	}
	var out [20]byte
	putBE32(out[0:], h0)
	putBE32(out[4:], h1)
	putBE32(out[8:], h2)
	putBE32(out[12:], h3)
	putBE32(out[16:], h4)
	return out
}

const hexDigits = "0123456789abcdef"

func hexEncode(b []byte) string {
	out := make([]byte, len(b)*2)
	for i, v := range b {
		out[i*2] = hexDigits[v>>4]
		out[i*2+1] = hexDigits[v&0xf]
	}
	return string(out)
}

func hexDecode(s string) ([20]byte, bool) {
	var out [20]byte
	if len(s) != 40 {
		return out, false
	}
	for i := 0; i < 20; i++ {
		hi, ok := fromHex(s[i*2])
		if !ok {
			return out, false
		}
		lo, ok := fromHex(s[i*2+1])
		if !ok {
			return out, false
		}
		out[i] = hi<<4 | lo
	}
	return out, true
}

func fromHex(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
