// SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104), in-tree.
//
// The GOOS=virelai stdlib cannot carry crypto packages: crypto/sha256 pulls
// crypto/internal/fips140/check, whose entropy self-check imports os — which
// does not exist on this GOOS (the same reason user/go/git/sha1.go is
// in-tree). ADR 0029 D1 keeps the TLS stack's primitives inside the tree's
// review discipline anyway. The K constants are the FIPS 180-4 table; the
// behavior pins are the RFC 8448 §3 transcript hashes, the FIPS 180-4 message
// vectors and a host-stdlib cross-check in sha_test.go — stock Go's audited
// implementation is the independent source ADR 0029 D2 requires.

package tls

// sha256K is the FIPS 180-4 §4.2.2 round-constant table (the first 32 bits of
// the fractional parts of the cube roots of the first 64 primes).
var sha256K = [64]uint32{
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

type sha256Digest struct {
	h  [8]uint32
	x  [64]byte
	nx int
	n  uint64
}

func sha256Init() sha256Digest {
	return sha256Digest{h: [8]uint32{
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	}}
}

func (d *sha256Digest) write(p []byte) {
	d.n += uint64(len(p))
	if d.nx > 0 {
		take := 64 - d.nx
		if take > len(p) {
			take = len(p)
		}
		copy(d.x[d.nx:], p[:take])
		d.nx += take
		p = p[take:]
		if d.nx == 64 {
			d.block(d.x[:])
			d.nx = 0
		}
	}
	for len(p) >= 64 {
		d.block(p[:64])
		p = p[64:]
	}
	if len(p) > 0 {
		copy(d.x[:], p)
		d.nx = len(p)
	}
}

func (d *sha256Digest) sum() [32]byte {
	// Padding (FIPS 180-4 §5.1.1): 0x80, zeros to 56 mod 64, then the 64-bit
	// big-endian bit length. padLen is 1..64 so one 64-byte buffer suffices.
	cp := *d
	length := cp.n
	padLen := int((56-(length+1)%64+64)%64) + 1
	var pad [64]byte
	pad[0] = 0x80
	bitLen := length * 8
	var tail [8]byte
	for i := 0; i < 8; i++ {
		tail[i] = byte(bitLen >> (56 - 8*i))
	}
	cp.write(pad[:padLen])
	cp.write(tail[:])
	if cp.nx != 0 {
		panic("sha256: padding did not land on a block boundary")
	}
	var out [32]byte
	for i, v := range cp.h {
		out[4*i] = byte(v >> 24)
		out[4*i+1] = byte(v >> 16)
		out[4*i+2] = byte(v >> 8)
		out[4*i+3] = byte(v)
	}
	return out
}

func sha256Sum(p []byte) [32]byte {
	d := sha256Init()
	d.write(p)
	return d.sum()
}

func (d *sha256Digest) block(p []byte) {
	var w [64]uint32
	for i := 0; i < 16; i++ {
		w[i] = uint32(p[4*i])<<24 | uint32(p[4*i+1])<<16 | uint32(p[4*i+2])<<8 | uint32(p[4*i+3])
	}
	for i := 16; i < 64; i++ {
		s0 := rotr32(w[i-15], 7) ^ rotr32(w[i-15], 18) ^ (w[i-15] >> 3)
		s1 := rotr32(w[i-2], 17) ^ rotr32(w[i-2], 19) ^ (w[i-2] >> 10)
		w[i] = w[i-16] + s0 + w[i-7] + s1
	}
	a, b, c, dd, e, f, g, h := d.h[0], d.h[1], d.h[2], d.h[3], d.h[4], d.h[5], d.h[6], d.h[7]
	for i := 0; i < 64; i++ {
		s1 := rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
		ch := (e & f) ^ (^e & g)
		t1 := h + s1 + ch + sha256K[i] + w[i]
		s0 := rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
		maj := (a & b) ^ (a & c) ^ (b & c)
		t2 := s0 + maj
		h, g, f = g, f, e
		e = dd + t1
		dd, c, b = c, b, a
		a = t1 + t2
	}
	d.h[0] += a
	d.h[1] += b
	d.h[2] += c
	d.h[3] += dd
	d.h[4] += e
	d.h[5] += f
	d.h[6] += g
	d.h[7] += h
}

func rotr32(x uint32, n uint) uint32 {
	return x>>n | x<<(32-n)
}

// hmacSha256 computes HMAC-SHA256 (RFC 2104) over msg with key. A key
// longer than the 64-byte block is hashed first (RFC 2104 §3).
func hmacSha256(key, msg []byte) [32]byte {
	var k [64]byte
	if len(key) > 64 {
		hashed := sha256Sum(key)
		copy(k[:], hashed[:])
	} else {
		copy(k[:], key)
	}
	for i := range k {
		k[i] ^= 0x36
	}
	inner := sha256Init()
	inner.write(k[:])
	inner.write(msg)
	ik := inner.sum()
	for i := range k {
		k[i] ^= 0x36 ^ 0x5c
	}
	outer := sha256Init()
	outer.write(k[:])
	outer.write(ik[:])
	return outer.sum()
}
