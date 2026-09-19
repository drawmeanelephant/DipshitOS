// ECDSA verification (FIPS 186-4 §4.1.4) over P-256 and P-384, on the
// Montgomery core from mont.go. Curve constants come from the generated
// vectors (curveP256params / curveP384params — OpenSSL `ecparam -param_enc
// explicit -text` origin), never typed by hand. Signature pins are the
// OpenSSL-generated vectors, which include mutated cases that must fail.
//
// All curve arithmetic runs on public data, so per ADR 0029's declared limits
// this is not constant-time.

package tls

// ecCurve is a Weierstrass curve with a = -3 (P-256 and P-384 both).
// Montgomery-form discipline: every field value stored is v·R mod p; montMul,
// addMod and subMod all preserve that form.
type ecCurve struct {
	f   *montCtx // field arithmetic mod p
	o   *montCtx // scalar arithmetic mod n
	bm  []uint64 // curve b, Montgomery form
	gx  []uint64 // base point, Montgomery affine
	gy  []uint64
	c3  []uint64 // Montgomery(3), for the a=-3 doubling formulas
	c4  []uint64 // Montgomery(4)
	c8  []uint64 // Montgomery(8)
	pBE []byte   // p in big-endian bytes (the affine coordinate width)
}

func newECCurve(params curveParams) (*ecCurve, error) {
	pBytes := hexDecode(params.p)
	// The generated constants carry openssl's leading sign byte; the curve
	// coordinate width is the minimal big-endian encoding.
	z := 0
	for z < len(pBytes)-1 && pBytes[z] == 0 {
		z++
	}
	pBytes = pBytes[z:]
	f, err := newMont(pBytes)
	if err != nil {
		return nil, err
	}
	o, err := newMont(hexDecode(params.n))
	if err != nil {
		return nil, err
	}
	return &ecCurve{
		f:   f,
		o:   o,
		bm:  f.toMont(f.fromBE(hexDecode(params.b))),
		gx:  f.toMont(f.fromBE(hexDecode(params.gx))),
		gy:  f.toMont(f.fromBE(hexDecode(params.gy))),
		c3:  f.toMont(montOne(f, 3)),
		c4:  f.toMont(montOne(f, 4)),
		c8:  f.toMont(montOne(f, 8)),
		pBE: pBytes,
	}, nil
}

func montOne(f *montCtx, v uint64) []uint64 {
	one := make([]uint64, f.nlimbs)
	one[0] = v
	return one
}

func hexDecode(s string) []byte {
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		out[i] = hexVal(s[2*i])<<4 | hexVal(s[2*i+1])
	}
	return out
}

func hexVal(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}

// ecJacobian is a point in Jacobian coordinates over the Montgomery field;
// an all-zero z is the point at infinity.
type ecJacobian struct {
	x, y, z []uint64
}

func (c *ecCurve) clone(p *ecJacobian) *ecJacobian {
	return &ecJacobian{
		x: append([]uint64{}, p.x...),
		y: append([]uint64{}, p.y...),
		z: append([]uint64{}, p.z...),
	}
}

func (c *ecCurve) infinity() *ecJacobian {
	return &ecJacobian{
		x: make([]uint64, c.f.nlimbs),
		y: make([]uint64, c.f.nlimbs),
		z: make([]uint64, c.f.nlimbs),
	}
}

// ecDouble implements the a = -3 Jacobian doubling formulas.
func (c *ecCurve) ecDouble(p *ecJacobian) *ecJacobian {
	if isZeroLimb(p.z) {
		return c.infinity()
	}
	f := c.f
	delta := f.montMul(p.z, p.z)
	gamma := f.montMul(p.y, p.y)
	beta := f.montMul(p.x, gamma)
	alpha := f.montMul(f.montMul(f.subMod(p.x, delta), f.addMod(p.x, delta)), c.c3)
	a2 := f.montMul(alpha, alpha)
	eightBeta := f.montMul(beta, c.c8)
	x3 := f.subMod(a2, eightBeta)
	yz := f.addMod(p.y, p.z)
	z3 := f.montMul(yz, yz)
	z3 = f.subMod(z3, gamma)
	z3 = f.subMod(z3, delta)
	fourBeta := f.montMul(beta, c.c4)
	y3 := f.subMod(fourBeta, x3)
	y3 = f.montMul(alpha, y3)
	gamma2 := f.montMul(gamma, gamma)
	y3 = f.subMod(y3, f.montMul(gamma2, c.c8))
	return &ecJacobian{x: x3, y: y3, z: z3}
}

// ecAdd is general Jacobian addition.
func (c *ecCurve) ecAdd(p, q *ecJacobian) *ecJacobian {
	if isZeroLimb(p.z) {
		return c.clone(q)
	}
	if isZeroLimb(q.z) {
		return c.clone(p)
	}
	f := c.f
	z1z1 := f.montMul(p.z, p.z)
	z2z2 := f.montMul(q.z, q.z)
	u1 := f.montMul(p.x, z2z2)
	u2 := f.montMul(q.x, z1z1)
	s1 := f.montMul(f.montMul(p.y, q.z), z2z2)
	s2 := f.montMul(f.montMul(q.y, p.z), z1z1)
	h := f.subMod(u2, u1)
	r := f.subMod(s2, s1)
	if isZeroLimb(h) {
		if isZeroLimb(r) {
			return c.ecDouble(p)
		}
		return c.infinity()
	}
	hh := f.montMul(h, h)
	hhh := f.montMul(h, hh)
	v := f.montMul(u1, hh)
	x3 := f.subMod(f.montMul(r, r), hhh)
	x3 = f.subMod(x3, v)
	x3 = f.subMod(x3, v)
	y3 := f.subMod(v, x3)
	y3 = f.montMul(r, y3)
	y3 = f.subMod(y3, f.montMul(s1, hhh))
	z3 := f.montMul(f.montMul(p.z, q.z), h)
	return &ecJacobian{x: x3, y: y3, z: z3}
}

// ecScalarMul computes k*P, MSB-first double-and-add (public data).
func (c *ecCurve) ecScalarMul(k []uint64, p *ecJacobian) *ecJacobian {
	hb := -1
	for i := len(k) - 1; i >= 0 && hb < 0; i-- {
		for bit := 63; bit >= 0; bit-- {
			if (k[i]>>uint(bit))&1 != 0 {
				hb = i*64 + bit
				break
			}
		}
	}
	res := c.infinity()
	if hb < 0 {
		return res
	}
	addend := c.clone(p)
	for i := hb; i >= 0; i-- {
		res = c.ecDouble(res)
		if (k[i/64]>>uint(i%64))&1 != 0 {
			res = c.ecAdd(res, addend)
		}
	}
	return res
}

// ecAffine converts a Jacobian point to affine Montgomery (x, y).
func (c *ecCurve) ecAffine(p *ecJacobian) ([]uint64, []uint64, bool) {
	if isZeroLimb(p.z) {
		return nil, nil, false
	}
	f := c.f
	ziM := f.toMont(f.invMod(f.fromMont(p.z)))
	zi2M := f.montMul(ziM, ziM)
	zi3M := f.montMul(zi2M, ziM)
	return f.montMul(p.x, zi2M), f.montMul(p.y, zi3M), true
}

// verifyECDSA checks an (r, s) signature over digest z against the affine
// public point (qx, qy). The digest length must match the curve coordinate
// width (SHA-256 for P-256, SHA-384 for P-384), so the "leftmost order bits"
// truncation of FIPS 186-4 4.1.4 is the straight decode.
func (c *ecCurve) verifyECDSA(qx, qy, rBig, sBig, z []byte) bool {
	f, o := c.f, c.o
	r := o.fromBE(rBig)
	s := o.fromBE(sBig)
	if o.cmp(r, o.n) >= 0 || o.cmp(s, o.n) >= 0 {
		return false
	}
	if isZeroLimb(r) || isZeroLimb(s) {
		return false
	}
	if len(z) != len(c.pBE) || len(qx) != len(c.pBE) || len(qy) != len(c.pBE) {
		return false
	}
	zz := o.fromBE(z)
	w := o.invMod(s)
	u1 := o.mulMod(zz, w)
	u2 := o.mulMod(r, w)
	p1 := c.ecScalarMul(u1, &ecJacobian{x: c.gx, y: c.gy, z: f.toMont(montOne(f, 1))})
	p2 := c.ecScalarMul(u2, &ecJacobian{
		x: f.toMont(f.fromBE(qx)),
		y: f.toMont(f.fromBE(qy)),
		z: f.toMont(montOne(f, 1)),
	})
	sum := c.ecAdd(p1, p2)
	xx, _, ok := c.ecAffine(sum)
	if !ok {
		return false
	}
	// v = x_aff mod n. p < 2n for both curves, so one conditional subtract
	// of n is an exact reduction (subMod re-adds n on borrow, which is the
	// identity when v < n already).
	plain := f.fromMont(xx)
	v := o.subMod(plain, o.n)
	return o.cmp(v, r) == 0
}
