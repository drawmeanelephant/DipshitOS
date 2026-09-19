// AES-128 (FIPS 197) and AES-GCM (NIST SP 800-38D, RFC 8439), in-tree — the
// mandatory TLS_AES_128_GCM_SHA256 suite's cipher. Same rationale as
// sha256.go: the GOOS=virelai stdlib cannot carry crypto packages.
//
// The S-box is not transcribed: it is generated at init from the GF(2^8)
// multiplicative inverse (via generator-3 log/antilog tables) composed with
// the FIPS 197 §5.1.1 affine transform, and init PANICS unless the anchors
// from FIPS 197's example (00->63, 01->7c, 53->ed) hold. A wrong construction
// therefore cannot ship silently. Behavior pins: RFC 8439 §5.2's AES-GCM
// vector, NIST GCM test cases 1-2, and a host-stdlib cross-check over random
// lengths.
//
// Side-channel posture matches the Zig client's declared limit (ADR 0029):
// the table-based SubBytes is not cache-timing constant-time.

package tls

var aesSbox [256]byte
var aesSboxInit bool

func init() {
	// exp/log tables over GF(2^8) with generator 3 (0x03 is primitive).
	var log [256]byte
	var exp [255]byte
	x := 1
	for i := 0; i < 255; i++ {
		exp[i] = byte(x)
		log[x] = byte(i)
		x ^= (x << 1) ^ (0x11b & -(x >> 7))
	}
	// The S-box (FIPS 197 §5.1.1): multiplicative inverse composed with the
	// affine transform s = inv ^ rotl(inv,1) ^ rotl(inv,2) ^ rotl(inv,3) ^
	// rotl(inv,4) ^ 0x63.
	for i := 0; i < 256; i++ {
		var inv byte
		if i != 0 {
			// inv = 3^(255 - log3(i)) mod 255 in the exponent; index mod 255
			// so the inverse of 1 (log 0) lands on exp[0].
			inv = exp[(255-int(log[i]))%255]
		}
		aesSbox[i] = inv ^ rotl8(inv, 1) ^ rotl8(inv, 2) ^ rotl8(inv, 3) ^ rotl8(inv, 4) ^ 0x63
	}
	if aesSbox[0x00] != 0x63 || aesSbox[0x01] != 0x7c || aesSbox[0x53] != 0xed {
		panic("aesgcm: sbox anchors from FIPS 197 do not hold")
	}
	aesSboxInit = true
}

func rotl8(x byte, n uint) byte {
	return x<<n | x>>(8-n)
}

// gmul8 is multiplication in GF(2^8) modulo 0x11b (FIPS 197 §4.2).
func gmul8(a, b byte) byte {
	var out byte
	for b != 0 {
		if b&1 != 0 {
			out ^= a
		}
		hi := a & 0x80
		a <<= 1
		if hi != 0 {
			a ^= 0x1b
		}
		b >>= 1
	}
	return out
}

// aes128 is an expanded-key context for the forward cipher (GCM only needs
// encryption).
type aes128 struct {
	rk [11][16]byte // round keys
}

func newAES128(key []byte) (*aes128, error) {
	if len(key) != 16 {
		return nil, errAESKeyLen
	}
	a := &aes128{}
	copy(a.rk[0][:], key)
	rcon := byte(1)
	for round := 1; round <= 10; round++ {
		prev := &a.rk[round-1]
		cur := &a.rk[round]
		// temp = SubWord(RotWord(prev word 3)) ^ Rcon (FIPS 197 §5.2).
		t := [4]byte{aesSbox[prev[13]] ^ rcon, aesSbox[prev[14]], aesSbox[prev[15]], aesSbox[prev[12]]}
		for w := 0; w < 4; w++ {
			if w > 0 {
				t = [4]byte{cur[4*(w-1)], cur[4*(w-1)+1], cur[4*(w-1)+2], cur[4*(w-1)+3]}
			}
			for i := 0; i < 4; i++ {
				cur[4*w+i] = prev[4*w+i] ^ t[i]
			}
		}
		rcon = gmul8(rcon, 2)
	}
	return a, nil
}

// encryptBlock encrypts one 16-byte block in place (src -> dst).
func (a *aes128) encryptBlock(dst, src []byte) {
	var s [16]byte
	copy(s[:], src)
	addRoundKey(s[:], &a.rk[0])
	for round := 1; round <= 9; round++ {
		for i := 0; i < 16; i++ {
			s[i] = aesSbox[s[i]]
		}
		shiftRows(&s)
		mixColumns(&s)
		addRoundKey(s[:], &a.rk[round])
	}
	for i := 0; i < 16; i++ {
		s[i] = aesSbox[s[i]]
	}
	shiftRows(&s)
	addRoundKey(s[:], &a.rk[10])
	copy(dst, s[:])
}

func addRoundKey(s []byte, k *[16]byte) {
	for i := range s {
		s[i] ^= k[i]
	}
}

// shiftRows operates on the FIPS 197 state (column-major: s[r + 4c]).
func shiftRows(s *[16]byte) {
	var t [16]byte
	copy(t[:], s[:])
	// Row 1: rotate left by 1.
	s[1] = t[5]
	s[5] = t[9]
	s[9] = t[13]
	s[13] = t[1]
	// Row 2: rotate left by 2.
	s[2] = t[10]
	s[6] = t[14]
	s[10] = t[2]
	s[14] = t[6]
	// Row 3: rotate left by 3.
	s[3] = t[15]
	s[7] = t[3]
	s[11] = t[7]
	s[15] = t[11]
}

func mixColumns(s *[16]byte) {
	for c := 0; c < 4; c++ {
		i := 4 * c
		a0, a1, a2, a3 := s[i], s[i+1], s[i+2], s[i+3]
		s[i] = gmul8(a0, 2) ^ gmul8(a1, 3) ^ a2 ^ a3
		s[i+1] = a0 ^ gmul8(a1, 2) ^ gmul8(a2, 3) ^ a3
		s[i+2] = a0 ^ a1 ^ gmul8(a2, 2) ^ gmul8(a3, 3)
		s[i+3] = gmul8(a0, 3) ^ a1 ^ a2 ^ gmul8(a3, 2)
	}
}

// ---------------------------------------------------------------------------
// GCM (NIST SP 800-38D §7; RFC 8439 is the worked example).
// ---------------------------------------------------------------------------

// gcmHashKey is H = E_K(0^128), the GHASH key derived per connection.
type gcmHashKey struct {
	h [16]byte
}

func newGCMHashKey(a *aes128) gcmHashKey {
	var zero [16]byte
	k := gcmHashKey{}
	a.encryptBlock(k.h[:], zero[:])
	return k
}

// ghashMul computes Y = Y·X in GF(2^128) with the NIST bit order (the first
// bit of the first byte is the most significant coefficient). Bit-at-a-time
// shift-and-reduce; the reduction polynomial is R = 0xE1 << 120.
func ghashMul(y, x *[16]byte) {
	var z [16]byte
	var v [16]byte
	copy(v[:], x[:])
	for bit := 0; bit < 128; bit++ {
		if y[bit/8]&(0x80>>uint(bit%8)) != 0 {
			for i := 0; i < 16; i++ {
				z[i] ^= v[i]
			}
		}
		lsb := v[15] & 1
		// v >>= 1 (MSB-first bit order: shift right across the byte array)
		for i := 15; i > 0; i-- {
			v[i] = v[i]>>1 | (v[i-1]&1)<<7
		}
		v[0] >>= 1
		if lsb != 0 {
			v[0] ^= 0xe1
		}
	}
	copy(y[:], z[:])
}

// ghash computes GHASH_H(A || pad || C || pad || len(A)64 || len(C)64).
func (k gcmHashKey) ghash(aad, ct []byte) [16]byte {
	var y [16]byte
	var buf [16]byte
	consume := func(p []byte) {
		for len(p) >= 16 {
			for i := 0; i < 16; i++ {
				y[i] ^= p[i]
			}
			ghashMul(&y, &k.h)
			p = p[16:]
		}
		if len(p) > 0 {
			for i := range buf {
				buf[i] = 0
			}
			copy(buf[:], p)
			for i := 0; i < 16; i++ {
				y[i] ^= buf[i]
			}
			ghashMul(&y, &k.h)
		}
	}
	consume(aad)
	consume(ct)
	var lens [16]byte
	putBE64(lens[:8], uint64(len(aad))*8)
	putBE64(lens[8:], uint64(len(ct))*8)
	for i := 0; i < 16; i++ {
		y[i] ^= lens[i]
	}
	ghashMul(&y, &k.h)
	return y
}

func putBE64(p []byte, v uint64) {
	for i := 0; i < 8; i++ {
		p[i] = byte(v >> (56 - 8*i))
	}
}

// gcmSeal encrypts plaintext with a 12-byte nonce and appends a 16-byte tag.
// out must be len(pt)+16.
func gcmSeal(a *aes128, out, pt, aad, nonce []byte) error {
	if len(nonce) != 12 || len(out) != len(pt)+16 {
		return errGCMArgs
	}
	var j0 [16]byte
	copy(j0[:12], nonce)
	j0[15] = 1
	gcmCrypt(a, out[:len(pt)], pt, &j0)
	k := newGCMHashKey(a)
	s := k.ghash(aad, out[:len(pt)])
	var tagMask [16]byte
	a.encryptBlock(tagMask[:], j0[:])
	for i := 0; i < 16; i++ {
		out[len(pt)+i] = s[i] ^ tagMask[i]
	}
	return nil
}

// gcmOpen decrypts and verifies; on tag failure nothing is written to out
// (decrypt-then-verify, fail closed).
func gcmOpen(a *aes128, out, ct, aad, nonce []byte) error {
	if len(nonce) != 12 || len(ct) < 16 || len(out) != len(ct)-16 {
		return errGCMArgs
	}
	var j0 [16]byte
	copy(j0[:12], nonce)
	j0[15] = 1
	k := newGCMHashKey(a)
	s := k.ghash(aad, ct[:len(ct)-16])
	var tagMask [16]byte
	a.encryptBlock(tagMask[:], j0[:])
	var expected [16]byte
	for i := 0; i < 16; i++ {
		expected[i] = s[i] ^ tagMask[i]
	}
	if !ctEqual16(&expected, ct[len(ct)-16:]) {
		return errGCMTagMismatch
	}
	gcmCrypt(a, out, ct[:len(ct)-16], &j0)
	return nil
}

// gcmCrypt is the CTR mode body: the data stream starts at inc32(J0) — J0
// itself is reserved for the tag mask (SP 800-38D §7.1).
func gcmCrypt(a *aes128, out, pt []byte, j0 *[16]byte) {
	var ctr [16]byte
	copy(ctr[:], j0[:])
	var stream [16]byte
	for done := 0; done < len(pt); done += 16 {
		// incr32: increment only the right 32 bits (SP 800-38D §6.2).
		for i := 15; i >= 12; i-- {
			ctr[i]++
			if ctr[i] != 0 {
				break
			}
		}
		a.encryptBlock(stream[:], ctr[:])
		n := len(pt) - done
		if n > 16 {
			n = 16
		}
		for i := 0; i < n; i++ {
			out[done+i] = pt[done+i] ^ stream[i]
		}
	}
}

// ctEqual16 is a constant-time 16-byte tag compare.
func ctEqual16(a *[16]byte, b []byte) bool {
	var v byte
	for i := 0; i < 16; i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}
