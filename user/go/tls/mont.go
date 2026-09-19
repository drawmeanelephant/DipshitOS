// A small Montgomery-arithmetic core over an odd modulus (big-endian byte
// input/output, little-endian uint64 limbs). It exists for two consumers:
// ECDSA verification over the P-256/P-384 field and order, and RSA-2048/3072
// PKCS#1 v1.5 / PSS signature verification. All of it operates on PUBLIC
// data, so per ADR 0029's declared limits these paths are not constant-time.
// Pins: the OpenSSL-generated RSA and ECDSA signature vectors (each asserted
// to verify, and a mutated signature not to, before the source vector file
// was written) plus host-stdlib cross-checks.

package tls

import "math/bits"

type montCtx struct {
	n      []uint64 // modulus, little-endian limbs, no leading zero limbs
	n0     uint64   // -n^-1 mod 2^64
	r2     []uint64 // R^2 mod n (R = 2^(64*nlimbs))
	nlimbs int
	scr    []uint64 // CIOS scratch (nl+2 limbs); a ctx is not goroutine-safe
}

func newMont(modBE []byte) (*montCtx, error) {
	// Strip leading zero bytes.
	i := 0
	for i < len(modBE) && modBE[i] == 0 {
		i++
	}
	mod := modBE[i:]
	if len(mod) == 0 || mod[len(mod)-1]&1 == 0 {
		return nil, errMontOddModulus
	}
	m := &montCtx{}
	m.nlimbs = (len(mod) + 7) / 8
	m.n = make([]uint64, m.nlimbs)
	// Big-endian bytes -> little-endian limbs.
	for bi := 0; bi < len(mod); bi++ {
		b := mod[len(mod)-1-bi]
		m.n[bi/8] |= uint64(b) << (8 * (bi % 8))
	}
	// n0inv = n^-1 mod 2^64 by Newton iteration, then negate.
	n0inv := uint64(1)
	for iter := 0; iter < 6; iter++ {
		n0inv *= 2 - m.n[0]*n0inv
	}
	m.n0 = ^n0inv + 1
	// R mod n by doubling 2^1..2^(64*nlimbs) mod n, then keep doubling for
	// R^2 (the Montgomery conversion constant). Doubling mod n is add mod n.
	rem := make([]uint64, m.nlimbs)
	rem[0] = 1
	steps := uint(64 * m.nlimbs)
	for s := uint(0); s < steps; s++ {
		m.dblInto(rem, rem)
	}
	m.r2 = make([]uint64, m.nlimbs)
	copy(m.r2, rem)
	for s := uint(0); s < steps; s++ {
		m.dblInto(m.r2, m.r2)
	}
	return m, nil
}

func (m *montCtx) dblInto(in, out []uint64) {
	var c uint64
	for i := 0; i < m.nlimbs; i++ {
		out[i], c = bits.Add64(in[i], in[i], c)
	}
	// Reduce: while >= n subtract once (the value here is < 2n so one
	// conditional subtract suffices).
	if c != 0 || m.cmp(out, m.n) >= 0 {
		var b uint64
		for i := 0; i < m.nlimbs; i++ {
			out[i], b = bits.Sub64(out[i], m.n[i], b)
		}
	}
}

func (m *montCtx) cmp(a, b []uint64) int {
	for i := m.nlimbs - 1; i >= 0; i-- {
		switch {
		case a[i] > b[i]:
			return 1
		case a[i] < b[i]:
			return -1
		}
	}
	return 0
}

// montMul computes x·y·R^-1 mod n: a schoolbook product into 2*nl limbs,
// then a separate REDC reduction. Every multi-word carry is added as a full
// ADDEND with its own Add64 (carry-in must stay 0/1 — a multi-bit carry-in is
// silently truncated on arm64), and the one place a word-sized carry can
// itself overflow (hi + two carries == 2^64) is tracked with an explicit
// overflow bit. Scratch is carried in the context: a single montCtx is NOT
// safe for concurrent use.
func (m *montCtx) montMul(x, y []uint64) []uint64 {
	nl := m.nlimbs
	t := m.scratch() // 2*nl+2 limbs, zeroed

	// Phase 1: t = x * y (schoolbook, carries fully propagated).
	for i := 0; i < nl; i++ {
		var c, co uint64
		for j := 0; j < nl; j++ {
			hi, lo := bits.Mul64(x[j], y[i])
			s, k1 := bits.Add64(t[i+j], lo, 0)
			s, k2 := bits.Add64(s, c, 0)
			s, k3 := bits.Add64(s, co, 0)
			t[i+j] = s
			c = hi + k1 + k2 + k3
			co = b2b(c < hi) // c wrapped past 2^64
		}
		s, k1 := bits.Add64(t[i+nl], c, 0)
		s, k2 := bits.Add64(s, co, 0)
		t[i+nl] = s
		t[i+nl+1] += k1 + k2
	}

	// Phase 2: REDC — for each limb, t += mi * n * R^i (mi = t[i]*n0).
	for i := 0; i < nl; i++ {
		mi := t[i] * m.n0
		var c, co uint64
		for j := 0; j < nl; j++ {
			hi, lo := bits.Mul64(mi, m.n[j])
			s, k1 := bits.Add64(t[i+j], lo, 0)
			s, k2 := bits.Add64(s, c, 0)
			s, k3 := bits.Add64(s, co, 0)
			t[i+j] = s
			c = hi + k1 + k2 + k3
			co = b2b(c < hi)
		}
		// The addout must propagate into the high half; it cannot overflow
		// past t[2*nl+1] (REDC's bound).
		s, k1 := bits.Add64(t[i+nl], c, 0)
		s, k2 := bits.Add64(s, co, 0)
		t[i+nl] = s
		t[i+nl+1] += k1 + k2
	}

	// Result = t[nl .. 2nl] (REDC's result is < 2n but may need nl+1 limbs:
	// the top limb can be 1 when the value exceeds R). One conditional
	// subtract of n, over the full nl+1 limbs, brings it below n.
	res := make([]uint64, nl+1)
	copy(res, t[nl:2*nl+1])
	if res[nl] != 0 || m.cmp(res[:nl], m.n) >= 0 {
		var b uint64
		for i := 0; i < nl; i++ {
			res[i], b = bits.Sub64(res[i], m.n[i], b)
		}
		// n < R, so the subtraction never borrows out of res[nl].
		res[nl] -= b
	}
	return res[:nl]
}

// b2b is a branchless boolean: 1 when true, 0 when false.
func b2b(v bool) uint64 {
	if v {
		return 1
	}
	return 0
}

func (m *montCtx) scratch() []uint64 {
	if m.scr == nil {
		m.scr = make([]uint64, 2*m.nlimbs+2)
	}
	for i := range m.scr {
		m.scr[i] = 0
	}
	return m.scr
}

// fromBE decodes big-endian bytes into plain (non-Montgomery) limbs.
func (m *montCtx) fromBE(b []byte) []uint64 {
	out := make([]uint64, m.nlimbs)
	for bi := 0; bi < len(b) && bi < m.nlimbs*8; bi++ {
		v := b[len(b)-1-bi]
		out[bi/8] |= uint64(v) << (8 * (bi % 8))
	}
	return out
}

// toBE encodes little-endian limbs as big-endian bytes of the context width.
func (m *montCtx) toBE(a []uint64) []byte {
	out := make([]byte, m.nlimbs*8)
	for i := 0; i < m.nlimbs; i++ {
		for j := 0; j < 8; j++ {
			out[len(out)-1-(i*8+j)] = byte(a[i] >> (8 * j))
		}
	}
	// Trim leading zeros (keep at least one byte).
	i := 0
	for i < len(out)-1 && out[i] == 0 {
		i++
	}
	return out[i:]
}

// toMont converts plain limbs into Montgomery form (a·R mod n).
func (m *montCtx) toMont(a []uint64) []uint64 {
	return m.montMul(a, m.r2)
}

// fromMont converts Montgomery limbs back to plain limbs.
func (m *montCtx) fromMont(a []uint64) []uint64 {
	one := make([]uint64, m.nlimbs)
	one[0] = 1
	return m.montMul(a, one)
}

// mulMod multiplies two plain values mod n.
func (m *montCtx) mulMod(a, b []uint64) []uint64 {
	return m.fromMont(m.montMul(m.toMont(a), m.toMont(b)))
}

// expMod computes a^e mod n where e is little-endian limbs (plain in, plain
// out). The exponent is public data, so this is not constant-time.
func (m *montCtx) expMod(a, e []uint64) []uint64 {
	am := m.toMont(a)
	res := m.toMont(m.one())
	// Highest set bit of the exponent.
	hb := -1
	for i := m.nlimbs - 1; i >= 0 && hb < 0; i-- {
		for bit := 63; bit >= 0; bit-- {
			if (e[i]>>uint(bit))&1 != 0 {
				hb = i*64 + bit
				break
			}
		}
	}
	if hb < 0 {
		return m.fromMont(res) // a^0 = 1
	}
	for i := hb; i >= 0; i-- {
		res = m.montMul(res, res)
		if (e[i/64]>>uint(i%64))&1 != 0 {
			res = m.montMul(res, am)
		}
	}
	return m.fromMont(res)
}

func (m *montCtx) one() []uint64 {
	one := make([]uint64, m.nlimbs)
	one[0] = 1
	return one
}

// invMod computes a^-1 mod n by Fermat (n must be prime — the curve order and
// the values verified here always are).
func (m *montCtx) invMod(a []uint64) []uint64 {
	// exponent n-2
	nm2 := make([]uint64, m.nlimbs)
	copy(nm2, m.n)
	// subtract 2
	if nm2[0] < 2 {
		nm2[0] -= 2
		for i := 1; i < m.nlimbs; i++ {
			if nm2[i] == 0 {
				nm2[i] = ^uint64(0)
			} else {
				nm2[i]--
				break
			}
		}
	} else {
		nm2[0] -= 2
	}
	return m.expMod(a, nm2)
}

// subMod computes a-b mod n for plain values.
func (m *montCtx) subMod(a, b []uint64) []uint64 {
	out := make([]uint64, m.nlimbs)
	var brr uint64
	for i := 0; i < m.nlimbs; i++ {
		out[i], brr = bits.Sub64(a[i], b[i], brr)
	}
	if brr != 0 {
		// add n back
		var c uint64
		for i := 0; i < m.nlimbs; i++ {
			out[i], c = bits.Add64(out[i], m.n[i], c)
		}
	}
	return out
}

// addMod computes a+b mod n for plain values.
func (m *montCtx) addMod(a, b []uint64) []uint64 {
	out := make([]uint64, m.nlimbs)
	var c uint64
	for i := 0; i < m.nlimbs; i++ {
		out[i], c = bits.Add64(a[i], b[i], c)
	}
	if c != 0 || m.cmp(out, m.n) >= 0 {
		var bb uint64
		for i := 0; i < m.nlimbs; i++ {
			out[i], bb = bits.Sub64(out[i], m.n[i], bb)
		}
	}
	return out
}

// isZero reports whether every limb is zero.
func isZeroLimb(a []uint64) bool {
	var v uint64
	for _, l := range a {
		v |= l
	}
	return v == 0
}
