// Certificate chain validation: path building to a configured trust anchor,
// then RFC 5280 §6.1 checks at every step, exactly as the Zig client orders
// them. The verdict is a specific code (never a generic failure), and a
// self-issued certificate may not serve as its own trust anchor — the walk
// must terminate at an anchor in the store (ADR 0029 D4).

package tls

const maxPath = 8

// validationResult mirrors user/src/lib/tls/validate.zig's Result enum.
type validationResult int

const (
	resultValid validationResult = iota
	resultParseError
	resultNoPathToRoot
	resultSignatureVerificationFailed
	resultExpired
	resultNotYetValid
	resultNotACA
	resultPathLengthExceeded
	resultKeyUsageMissingKeyCertSign
	resultEKUNotServerAuth
	resultUnknownCriticalExtension
	resultUnsupportedSignatureAlgorithm
	resultNameConstraintViolation
	resultHostnameMismatch
)

// sigAlgAllowed reports whether TLS 1.3 permits the algorithm for
// certificates. Ed25519 is classified but not verifiable in this client, so
// it is excluded here (fail closed with a specific code, not a signature
// mystery).
func sigAlgAllowed(alg sigAlg) bool {
	switch alg {
	case sigAlgRSAPKCS1SHA256, sigAlgRSAPKCS1SHA384, sigAlgRSAPKCS1SHA512,
		sigAlgRSAPSS, sigAlgECDSASHA256, sigAlgECDSASHA384:
		return true
	}
	return false
}

// verifyCertSignature verifies cert's signature with issuer's public key.
func verifyCertSignature(c, issuer *cert) bool {
	switch c.sigAlg {
	case sigAlgRSAPKCS1SHA256:
		return issuer.key.kind == keyRSA && verifyRsaPkcs1(issuer.key.rsaModulus, issuer.key.rsaExponent, hashSHA256, c.tbs, c.signature)
	case sigAlgRSAPKCS1SHA384:
		return issuer.key.kind == keyRSA && verifyRsaPkcs1(issuer.key.rsaModulus, issuer.key.rsaExponent, hashSHA384, c.tbs, c.signature)
	case sigAlgRSAPKCS1SHA512:
		return issuer.key.kind == keyRSA && verifyRsaPkcs1(issuer.key.rsaModulus, issuer.key.rsaExponent, hashSHA512, c.tbs, c.signature)
	// RSASSA-PSS: the hash is carried in the params, which the parser does
	// not read; SHA-256 is the mandatory default and the common real case
	// (the same choice the Zig client makes).
	case sigAlgRSAPSS:
		return issuer.key.kind == keyRSA && verifyRsaPss(issuer.key.rsaModulus, issuer.key.rsaExponent, hashSHA256, c.tbs, c.signature)
	case sigAlgECDSASHA256, sigAlgECDSASHA384:
		return verifyECDSACert(c, issuer)
	}
	return false
}

func verifyECDSACert(c, issuer *cert) bool {
	if issuer.key.kind != keyEC {
		return false
	}
	point := issuer.key.point
	if len(point) < 1 || point[0] != 0x04 {
		return false
	}
	var curve *ecCurve
	var digest []byte
	switch {
	case c.sigAlg == sigAlgECDSASHA256 && issuer.key.curve == curveKindP256:
		h := sha256Sum(c.tbs)
		digest = h[:]
		curve = ecP256()
	case c.sigAlg == sigAlgECDSASHA384 && issuer.key.curve == curveKindP384:
		h := sha384Sum(c.tbs)
		digest = h[:]
		curve = ecP384()
	default:
		return false
	}
	// The DER ECDSA-Sig-Value: SEQUENCE { r INTEGER, s INTEGER }.
	outer := newDERReader(c.signature)
	seq, err := outer.expect(derTagSequence)
	if err != nil || !outer.atEnd() {
		return false
	}
	sr := newDERReader(seq.content)
	rElem, err := sr.expect(derTagInteger)
	if err != nil {
		return false
	}
	sElem, err := sr.expect(derTagInteger)
	if err != nil {
		return false
	}
	if !sr.atEnd() {
		return false
	}
	r, err := derInteger(rElem)
	if err != nil {
		return false
	}
	s, err := derInteger(sElem)
	if err != nil {
		return false
	}
	flen := (len(point) - 1) / 2
	return curve.verifyECDSA(point[1:1+flen], point[1+flen:], r, s, digest)
}

// Package-level curve contexts (built once; the constants are the generated
// vectors, so a bad build fails the first vector test).
var (
	ecP256Ctx *ecCurve
	ecP384Ctx *ecCurve
)

func ecP256() *ecCurve {
	if ecP256Ctx == nil {
		c, err := newECCurve(curveP256params)
		if err != nil {
			panic("tls: p256 context construction failed: " + err.Error())
		}
		ecP256Ctx = c
	}
	return ecP256Ctx
}

func ecP384() *ecCurve {
	if ecP384Ctx == nil {
		c, err := newECCurve(curveP384params)
		if err != nil {
			panic("tls: p384 context construction failed: " + err.Error())
		}
		ecP384Ctx = c
	}
	return ecP384Ctx
}

// matchSubtree is the DNS name-constraint match: ".example.com" matches
// "example.com" and any subdomain.
func matchSubtree(base, host []byte) bool {
	if len(base) == 0 || len(host) == 0 {
		return false
	}
	if base[0] == '.' {
		base = base[1:]
	}
	if eqlIgnoreCase(base, host) {
		return true
	}
	if len(host) <= len(base)+1 {
		return false
	}
	cut := len(host) - len(base) - 1
	if host[cut] != '.' {
		return false
	}
	return eqlIgnoreCase(host[cut+1:], base)
}

func checkNameConstraints(leaf, ca *cert) bool {
	if !ca.hasNameConstraints {
		return true
	}
	for i := 0; i < leaf.sanLen; i++ {
		g := leaf.san[i]
		if g.isIP {
			continue
		}
		if len(ca.ncPermittedDNS) != 0 {
			ok := false
			for _, p := range ca.ncPermittedDNS {
				if matchSubtree(p, g.dns) {
					ok = true
					break
				}
			}
			if !ok {
				return false
			}
		}
		for _, e := range ca.ncExcludedDNS {
			if matchSubtree(e, g.dns) {
				return false
			}
		}
	}
	return true
}

// validateChain validates leafDer against store, optionally through
// intermediates, for host at wall-clock time now.
func validateChain(leafDER []byte, intermediates [][]byte, store *trustStore, host []byte, now int64) validationResult {
	leaf, err := parseCert(leafDER)
	if err != nil {
		return resultParseError
	}
	parsed := make([]*cert, 0, len(intermediates))
	for _, d := range intermediates {
		if len(parsed) >= maxIntermediates {
			break
		}
		ic, err := parseCert(d)
		if err != nil {
			return resultParseError
		}
		parsed = append(parsed, ic)
	}

	// --- path building ---
	path := make([]*cert, 0, maxPath)
	path = append(path, leaf)
	current := leaf
	reachedAnchor := false
	for len(path) < maxPath {
		if root := store.findIssuer(current.issuerRaw); root != nil {
			path = append(path, root)
			reachedAnchor = true
			break
		}
		found := false
		for _, ic := range parsed {
			if string(ic.subjectRaw) == string(current.issuerRaw) {
				path = append(path, ic)
				current = ic
				found = true
				break
			}
		}
		if !found {
			return resultNoPathToRoot
		}
	}
	if !reachedAnchor {
		return resultNoPathToRoot
	}

	// --- per-step checks, leaf (0) through the cert below the root ---
	for i := 0; i+1 < len(path); i++ {
		c := path[i]
		iss := path[i+1]
		if !sigAlgAllowed(c.sigAlg) {
			return resultUnsupportedSignatureAlgorithm
		}
		if !verifyCertSignature(c, iss) {
			return resultSignatureVerificationFailed
		}
		if now < c.notBefore {
			return resultNotYetValid
		}
		if now > c.notAfter {
			return resultExpired
		}
		if c.hasUnknownCritical() {
			return resultUnknownCriticalExtension
		}
		if !iss.hasBasicConstraints || !iss.isCA {
			return resultNotACA
		}
		if iss.hasKeyUsage && iss.keyUsage&kuKeyCertSign == 0 {
			return resultKeyUsageMissingKeyCertSign
		}
		if iss.pathLen != nil && i > int(*iss.pathLen) {
			return resultPathLengthExceeded
		}
		if !checkNameConstraints(path[0], iss) {
			return resultNameConstraintViolation
		}
	}

	// --- root's own window and criticality ---
	root := path[len(path)-1]
	if now < root.notBefore {
		return resultNotYetValid
	}
	if now > root.notAfter {
		return resultExpired
	}
	if root.hasUnknownCritical() {
		return resultUnknownCriticalExtension
	}

	// --- leaf identity ---
	if !path[0].ekuOK() {
		return resultEKUNotServerAuth
	}
	if !verifyIdentity(path[0], []byte(host)).ok() {
		return resultHostnameMismatch
	}
	return resultValid
}
