// X.509 certificate parsing (RFC 5280 §4), DER-only, strict, view-based —
// the Go mirror of user/src/lib/tls/x509.zig's scope: everything the chain
// validator reads (version, serial, signature algorithm, issuer/subject CN,
// validity, SubjectPublicKeyInfo, subjectAltName, basicConstraints, keyUsage,
// extendedKeyUsage, nameConstraints, unknown-critical extensions). Over-
// capacity is an error, never a silent truncation; a malformed input returns
// an error, never a panic.

package tls

const (
	maxGeneralNames    = 64
	maxUnknownCritical = 16
	maxNC              = 12
	rsaMinModulusBytes = 256 // 2048-bit floor
)

// OIDs (exact DER content bytes).
var (
	oidCommonName       = []byte{0x55, 0x04, 0x03}
	oidRSAEncryption    = []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01}
	oidRSASSAPSS        = []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0a}
	oidSHA256WithRSA    = []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b}
	oidSHA384WithRSA    = []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c}
	oidSHA512WithRSA    = []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d}
	oidECPublicKey      = []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01}
	oidPrime256v1       = []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
	oidSecp384r1        = []byte{0x2b, 0x81, 0x04, 0x00, 0x22}
	oidEd25519          = []byte{0x2b, 0x65, 0x70}
	oidECDSASHA256      = []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02}
	oidECDSASHA384      = []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03}
	oidECDSASHA512      = []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04}
	oidSubjectAltName   = []byte{0x55, 0x1d, 0x11}
	oidBasicConstraints = []byte{0x55, 0x1d, 0x13}
	oidKeyUsage         = []byte{0x55, 0x1d, 0x0f}
	oidExtKeyUsage      = []byte{0x55, 0x1d, 0x25}
	oidNameConstraints  = []byte{0x55, 0x1d, 0x1e}
	oidServerAuth       = []byte{0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01}
)

// sigAlg classifies certificate signature algorithms (RFC 8446 §4.4.2.2's
// permitted set plus unknown).
type sigAlg int

const (
	sigAlgUnknown sigAlg = iota
	sigAlgRSAPKCS1SHA256
	sigAlgRSAPKCS1SHA384
	sigAlgRSAPKCS1SHA512
	sigAlgRSAPSS
	sigAlgECDSASHA256
	sigAlgECDSASHA384
	sigAlgECDSASHA512
	sigAlgEd25519
)

func classifySigAlg(oid []byte) sigAlg {
	switch {
	case derEqlOid(oid, oidSHA256WithRSA):
		return sigAlgRSAPKCS1SHA256
	case derEqlOid(oid, oidSHA384WithRSA):
		return sigAlgRSAPKCS1SHA384
	case derEqlOid(oid, oidSHA512WithRSA):
		return sigAlgRSAPKCS1SHA512
	case derEqlOid(oid, oidRSASSAPSS):
		return sigAlgRSAPSS
	case derEqlOid(oid, oidECDSASHA256):
		return sigAlgECDSASHA256
	case derEqlOid(oid, oidECDSASHA384):
		return sigAlgECDSASHA384
	case derEqlOid(oid, oidECDSASHA512):
		return sigAlgECDSASHA512
	case derEqlOid(oid, oidEd25519):
		return sigAlgEd25519
	}
	return sigAlgUnknown
}

// ecCurveKind names the SPKI curve.
type ecCurveKind int

const (
	curveKindNone ecCurveKind = iota
	curveKindP256
	curveKindP384
)

// keyKind / key mirror x509.zig's Key.
type keyKind int

const (
	keyUnsupported keyKind = iota
	keyRSA
	keyEC
	keyEd25519
)

type certKey struct {
	kind        keyKind
	curve       ecCurveKind
	rsaModulus  []byte
	rsaExponent []byte
	// point: the EC uncompressed point (or the Ed25519 32-byte key). Slices
	// the input DER — a view.
	point []byte
}

// generalName is a SAN entry: a DNS name (view) or an IP stored v4-mapped.
type generalName struct {
	dns  []byte
	ip   [16]byte
	isIP bool
}

// keyUsage bit positions (RFC 5280 §4.2.1.3).
const (
	kuDigitalSignature = 1 << 0
	kuKeyCertSign      = 1 << 5
)

// cert is the parsed certificate. Every slice is a view into the input DER;
// anything that must outlive it is copied by the caller.
type cert struct {
	der       []byte
	tbs       []byte // full tbsCertificate SEQUENCE, header included
	signature []byte // signatureValue BIT STRING payload
	version   int
	serial    []byte
	sigAlgOID []byte
	sigAlg    sigAlg
	issuerCN  []byte
	subjectCN []byte
	// Raw DER of the issuer/subject Name for exact path matching.
	issuerRaw  []byte
	subjectRaw []byte
	notBefore  int64
	notAfter   int64
	key        certKey

	hasSAN bool
	san    [maxGeneralNames]generalName
	sanLen int

	hasBasicConstraints bool
	isCA                bool
	pathLen             *uint8

	hasKeyUsage bool
	keyUsage    uint16

	hasEKU        bool
	ekuServerAuth bool

	hasNameConstraints bool
	ncPermittedDNS     [][]byte
	ncExcludedDNS      [][]byte

	unknownCritical [][]byte
}

func parseCert(derBytes []byte) (*cert, error) {
	c := &cert{der: derBytes}
	top := newDERReader(derBytes)
	certSeq, err := top.next()
	if err != nil {
		return nil, err
	}
	if certSeq.tag != derTagSequence || !top.atEnd() {
		return nil, errNotACertificate
	}
	body := newDERReader(certSeq.content)
	tbs, err := body.expect(derTagSequence)
	if err != nil {
		return nil, err
	}
	outerAlg, err := body.expect(derTagSequence)
	if err != nil {
		return nil, err
	}
	sigElem, err := body.expect(derTagBitString)
	if err != nil {
		return nil, err
	}
	if !body.atEnd() {
		return nil, errNotACertificate
	}
	c.tbs = tbs.raw
	sig, unused, err := derBitString(sigElem)
	if err != nil {
		return nil, err
	}
	if unused != 0 {
		return nil, errDER // signatureValue BIT STRINGs are whole octets
	}
	c.signature = sig

	algR := newDERReader(outerAlg.content)
	oidElem, err := algR.next()
	if err != nil {
		return nil, err
	}
	oidBytes, err := derOIDBytes(oidElem)
	if err != nil {
		return nil, err
	}
	c.sigAlgOID = oidBytes
	c.sigAlg = classifySigAlg(oidBytes)

	if err := parseTBS(tbs.content, c); err != nil {
		return nil, err
	}
	return c, nil
}

func parseTBS(buf []byte, c *cert) error {
	r := newDERReader(buf)
	e, err := r.next()
	if err != nil {
		return err
	}
	if e.isCtx(0) {
		vr := newDERReader(e.content)
		ve, err := vr.expect(derTagInteger)
		if err != nil {
			return err
		}
		v, err := derIntegerU64(ve)
		if err != nil {
			return err
		}
		if v > 2 {
			return errUnsupportedVersion
		}
		c.version = int(v) + 1
		e, err = r.next()
		if err != nil {
			return err
		}
	}
	if e.tag != derTagInteger {
		return errMissingField
	}
	serial, err := derInteger(e)
	if err != nil {
		return err
	}
	c.serial = serial

	if _, err := r.expect(derTagSequence); err != nil {
		return err // inner signature AlgorithmIdentifier
	}
	issuerElem, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	c.issuerCN, err = parseNameCN(issuerElem.content)
	if err != nil {
		return err
	}
	c.issuerRaw = issuerElem.raw

	validity, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	vr := newDERReader(validity.content)
	nb, err := vr.next()
	if err != nil {
		return err
	}
	if c.notBefore, err = derParseTime(nb); err != nil {
		return err
	}
	na, err := vr.next()
	if err != nil {
		return err
	}
	if c.notAfter, err = derParseTime(na); err != nil {
		return err
	}

	subjectElem, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	c.subjectCN, err = parseNameCN(subjectElem.content)
	if err != nil {
		return err
	}
	c.subjectRaw = subjectElem.raw

	spki, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	if err := parseSPKI(spki.content, c); err != nil {
		return err
	}

	for !r.atEnd() {
		x, err := r.next()
		if err != nil {
			return err
		}
		if x.isCtx(3) {
			if err := parseExtensions(x.content, c); err != nil {
				return err
			}
		} else if !x.isCtx(1) && !x.isCtx(2) {
			return errMissingField
		}
	}
	return nil
}

// parseNameCN returns the last commonName in the Name (nil if none).
func parseNameCN(buf []byte) ([]byte, error) {
	r := newDERReader(buf)
	var cn []byte
	for !r.atEnd() {
		rdn, err := r.expect(derTagSet)
		if err != nil {
			return nil, err
		}
		rr := newDERReader(rdn.content)
		for !rr.atEnd() {
			atv, err := rr.expect(derTagSequence)
			if err != nil {
				return nil, err
			}
			ar := newDERReader(atv.content)
			o, err := ar.next()
			if err != nil {
				return nil, err
			}
			oidB, err := derOIDBytes(o)
			if err != nil {
				return nil, err
			}
			val, err := ar.next()
			if err != nil {
				return nil, err
			}
			if derEqlOid(oidB, oidCommonName) {
				cn = val.content
			}
		}
	}
	return cn, nil
}

func parseSPKI(buf []byte, c *cert) error {
	r := newDERReader(buf)
	alg, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	spk, err := r.expect(derTagBitString)
	if err != nil {
		return err
	}
	bits, unused, err := derBitString(spk)
	if err != nil {
		return err
	}
	if unused != 0 {
		return errBadAlgorithm
	}
	ar := newDERReader(alg.content)
	o, err := ar.next()
	if err != nil {
		return err
	}
	oidB, err := derOIDBytes(o)
	if err != nil {
		return err
	}
	switch {
	case derEqlOid(oidB, oidRSAEncryption):
		kr := newDERReader(bits)
		ks, err := kr.expect(derTagSequence)
		if err != nil {
			return err
		}
		kk := newDERReader(ks.content)
		nElem, err := kk.next()
		if err != nil {
			return err
		}
		n, err := derInteger(nElem)
		if err != nil {
			return err
		}
		eElem, err := kk.next()
		if err != nil {
			return err
		}
		e, err := derInteger(eElem)
		if err != nil {
			return err
		}
		if len(n) < rsaMinModulusBytes {
			return errBadAlgorithm // < 2048-bit modulus
		}
		c.key = certKey{kind: keyRSA, rsaModulus: n, rsaExponent: e}
	case derEqlOid(oidB, oidECPublicKey):
		cElem, err := ar.next()
		if err != nil {
			return err
		}
		curveOID, err := derOIDBytes(cElem)
		if err != nil {
			return err
		}
		kind := curveKindNone
		if derEqlOid(curveOID, oidPrime256v1) {
			kind = curveKindP256
		} else if derEqlOid(curveOID, oidSecp384r1) {
			kind = curveKindP384
		}
		if kind == curveKindNone {
			return errBadAlgorithm
		}
		want := 1 + 32*2
		if kind == curveKindP384 {
			want = 1 + 48*2
		}
		if len(bits) < 1 || bits[0] != 0x04 || len(bits) != want {
			return errBadAlgorithm // uncompressed points only, exact length
		}
		c.key = certKey{kind: keyEC, curve: kind, point: bits}
	case derEqlOid(oidB, oidEd25519):
		if len(bits) != 32 {
			return errBadAlgorithm
		}
		c.key = certKey{kind: keyEd25519, point: bits}
	default:
		c.key = certKey{kind: keyUnsupported}
	}
	return nil
}

func parseExtensions(buf []byte, c *cert) error {
	outer := newDERReader(buf)
	seq, err := outer.expect(derTagSequence)
	if err != nil {
		return err
	}
	r := newDERReader(seq.content)
	for !r.atEnd() {
		ext, err := r.expect(derTagSequence)
		if err != nil {
			return err
		}
		er := newDERReader(ext.content)
		o, err := er.next()
		if err != nil {
			return err
		}
		oidB, err := derOIDBytes(o)
		if err != nil {
			return err
		}
		critical := false
		val, err := er.next()
		if err != nil {
			return err
		}
		if val.tag == derTagBoolean {
			critical, err = derBoolean(val)
			if err != nil {
				return err
			}
			val, err = er.next()
			if err != nil {
				return err
			}
		}
		if val.tag != derTagOctetString {
			return errBadExtension
		}
		content := val.content
		switch {
		case derEqlOid(oidB, oidSubjectAltName):
			if err := parseSAN(content, c); err != nil {
				return err
			}
		case derEqlOid(oidB, oidBasicConstraints):
			if err := parseBasicConstraints(content, c); err != nil {
				return err
			}
		case derEqlOid(oidB, oidKeyUsage):
			if err := parseKeyUsage(content, c); err != nil {
				return err
			}
		case derEqlOid(oidB, oidExtKeyUsage):
			if err := parseEKU(content, c); err != nil {
				return err
			}
		case derEqlOid(oidB, oidNameConstraints):
			if err := parseNameConstraints(content, c); err != nil {
				return err
			}
		default:
			if critical {
				if len(c.unknownCritical) >= maxUnknownCritical {
					return errTooManyExtensions
				}
				// Copy: the OID content is a view; the record must survive
				// the buffer it came from (ADR 0029 D4's view rule).
				cp := make([]byte, len(oidB))
				copy(cp, oidB)
				c.unknownCritical = append(c.unknownCritical, cp)
			}
		}
	}
	return nil
}

func parseSAN(buf []byte, c *cert) error {
	c.hasSAN = true
	r := newDERReader(buf)
	seq, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	g := newDERReader(seq.content)
	for !g.atEnd() {
		gn, err := g.next()
		if err != nil {
			return err
		}
		if gn.isCtx(2) { // dNSName
			if c.sanLen >= maxGeneralNames {
				return errTooManyExtensions
			}
			c.san[c.sanLen] = generalName{dns: gn.content}
			c.sanLen++
		} else if gn.isCtx(7) { // iPAddress
			if len(gn.content) != 4 && len(gn.content) != 16 {
				return errBadIPAddress
			}
			if c.sanLen >= maxGeneralNames {
				return errTooManyExtensions
			}
			var ip [16]byte
			if len(gn.content) == 4 {
				ip[10] = 0xff
				ip[11] = 0xff
				copy(ip[12:], gn.content)
			} else {
				copy(ip[:], gn.content)
			}
			c.san[c.sanLen] = generalName{ip: ip, isIP: true}
			c.sanLen++
		}
	}
	return nil
}

func parseBasicConstraints(buf []byte, c *cert) error {
	c.hasBasicConstraints = true
	r := newDERReader(buf)
	seq, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	s := newDERReader(seq.content)
	if !s.atEnd() {
		b, err := s.next()
		if err != nil {
			return err
		}
		isCA, err := derBoolean(b)
		if err != nil {
			return err
		}
		c.isCA = isCA
	}
	if !s.atEnd() {
		p, err := s.next()
		if err != nil {
			return err
		}
		v, err := derIntegerU64(p)
		if err != nil {
			return err
		}
		if v > 255 {
			return errBadExtension
		}
		pl := uint8(v)
		c.pathLen = &pl
	}
	if !s.atEnd() {
		return errBadExtension
	}
	return nil
}

func parseKeyUsage(buf []byte, c *cert) error {
	r := newDERReader(buf)
	bs, err := r.next()
	if err != nil {
		return err
	}
	payload, unused, err := derBitString(bs)
	if err != nil {
		return err
	}
	_ = unused // the trailing unused bits are zero by DER rule
	c.hasKeyUsage = true
	var k uint16
	for i := 0; i < len(payload) && i < 2; i++ {
		for b := 0; b < 8; b++ {
			if payload[i]&(0x80>>uint(b)) != 0 {
				k |= 1 << uint(i*8+b)
			}
		}
	}
	c.keyUsage = k
	return nil
}

func parseEKU(buf []byte, c *cert) error {
	c.hasEKU = true
	r := newDERReader(buf)
	seq, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	s := newDERReader(seq.content)
	for !s.atEnd() {
		o, err := s.next()
		if err != nil {
			return err
		}
		oidB, err := derOIDBytes(o)
		if err != nil {
			return err
		}
		if derEqlOid(oidB, oidServerAuth) {
			c.ekuServerAuth = true
		}
	}
	return nil
}

func parseNameConstraints(buf []byte, c *cert) error {
	c.hasNameConstraints = true
	c.ncPermittedDNS = nil
	c.ncExcludedDNS = nil
	r := newDERReader(buf)
	seq, err := r.expect(derTagSequence)
	if err != nil {
		return err
	}
	s := newDERReader(seq.content)
	for !s.atEnd() {
		field, err := s.next()
		if err != nil {
			return err
		}
		if !field.isCtx(0) && !field.isCtx(1) {
			return errBadExtension
		}
		permitted := field.isCtx(0)
		// The [0]/[1] tags are IMPLICIT: the content holds the GeneralSubtree
		// elements directly, with no inner SEQUENCE wrapper.
		lr := newDERReader(field.content)
		for !lr.atEnd() {
			sub, err := lr.expect(derTagSequence)
			if err != nil {
				return err
			}
			sr := newDERReader(sub.content)
			if sr.atEnd() {
				continue
			}
			base, err := sr.next()
			if err != nil {
				return err
			}
			if !base.isCtx(2) {
				continue // only DNS constraints are recorded
			}
			if permitted {
				if len(c.ncPermittedDNS) >= maxNC {
					return errTooManyExtensions
				}
				c.ncPermittedDNS = append(c.ncPermittedDNS, base.content)
			} else {
				if len(c.ncExcludedDNS) >= maxNC {
					return errTooManyExtensions
				}
				c.ncExcludedDNS = append(c.ncExcludedDNS, base.content)
			}
		}
	}
	return nil
}

// hasUnknownCritical reports whether any unknown CRITICAL extension was seen
// (validation must fail the chain, ADR 0029 D4).
func (c *cert) hasUnknownCritical() bool { return len(c.unknownCritical) > 0 }

// ekuOK applies RFC 5280 §4.2.1.12: absent EKU means unrestricted.
func (c *cert) ekuOK() bool { return !c.hasEKU || c.ekuServerAuth }
