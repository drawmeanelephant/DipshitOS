// RSASSA-PKCS1-v1_5 and RSASSA-PSS verification (RFC 8017 §8.2.2 / §8.1.2)
// over the Montgomery core. TLS 1.3 uses PSS with the digest's own length as
// the salt length; PKCS#1 v1.5 exists in the tree because real certificates
// still carry sha256/384/512WithRSAEncryption signatures. Pins: the
// OpenSSL-generated vectors (positive plus mutated-negative cases) for all
// three hashes and both paddings, and a host-stdlib cross-check.

package tls

type hashAlg int

const (
	hashSHA256 hashAlg = iota
	hashSHA384
	hashSHA512
)

func (h hashAlg) size() int {
	switch h {
	case hashSHA256:
		return 32
	case hashSHA384:
		return 48
	default:
		return 64
	}
}

// hashSum computes the digest of msg.
func (h hashAlg) hashSum(msg []byte) []byte {
	switch h {
	case hashSHA256:
		s := sha256Sum(msg)
		return s[:]
	case hashSHA384:
		s := sha384Sum(msg)
		return s[:]
	default:
		s := sha512Sum(msg)
		return s[:]
	}
}

// digestInfoPrefix is the EMSA-PKCS1-v1_5 DigestInfo DER prefix per hash
// (RFC 8017 §9.2 note 1): SEQUENCE { OID, NULL } with the following OCTET
// STRING header.
func (h hashAlg) digestInfoPrefix() []byte {
	switch h {
	case hashSHA256:
		return []byte{0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20}
	case hashSHA384:
		return []byte{0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30}
	default:
		return []byte{0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40}
	}
}

// rsaRSAEP applies the RSA public operation s^e mod n, returning the result
// as exactly len(n) big-endian bytes (leading zeros kept — EMSA padding is
// left-aligned).
func rsaRSAEP(nBE, eBE, sig []byte) []byte {
	m, err := newMont(nBE)
	if err != nil {
		return nil
	}
	eLimbs := m.fromBE(eBE)
	sLimbs := m.fromBE(sig)
	out := m.expMod(sLimbs, eLimbs)
	outBE := m.toBE(out)
	if len(outBE) > len(nBE) {
		return nil
	}
	// Left-pad to the modulus width.
	full := make([]byte, len(nBE))
	copy(full[len(nBE)-len(outBE):], outBE)
	return full
}

// verifyRsaPkcs1 checks an RSASSA-PKCS1-v1_5 signature over digest.
func verifyRsaPkcs1(nBE, eBE []byte, h hashAlg, digest, sig []byte) bool {
	if len(sig) == 0 || len(sig) > len(nBE) {
		return false
	}
	em := rsaRSAEP(nBE, eBE, sig)
	if em == nil {
		return false
	}
	// EM = 0x00 || 0x01 || PS(0xff.., >= 8) || 0x00 || DigestInfo
	if len(em) < len(h.digestInfoPrefix())+h.size()+11 {
		return false
	}
	if em[0] != 0x00 || em[1] != 0x01 {
		return false
	}
	i := 2
	for i < len(em) && em[i] == 0xff {
		i++
	}
	if i < 10 { // 0x01 + at least 8 bytes of PS
		return false
	}
	if i >= len(em) || em[i] != 0x00 {
		return false
	}
	i++
	t := append(append([]byte{}, h.digestInfoPrefix()...), digest...)
	if len(em)-i != len(t) {
		return false
	}
	var diff byte
	for j := range t {
		diff |= em[i+j] ^ t[j]
	}
	return diff == 0
}

// verifyRsaPss checks an RSASSA-PSS signature over digest with MGF1 and the
// same hash. The salt length is derived from DB's 0x01 separator rather than
// assumed, so both the TLS 1.3 convention (salt = digest length) and any
// other salt the signer chose verify; a malformed DB fails closed.
func verifyRsaPss(nBE, eBE []byte, h hashAlg, digest, sig []byte) bool {
	if len(sig) == 0 || len(sig) > len(nBE) {
		return false
	}
	// emBits = modBits - 1 and emLen = ceil(emBits/8) (RFC 8017 §9.1.2):
	// the encoded message is one bit shorter than the modulus, so the top
	// bit of DB is always masked off — even for octet-aligned moduli.
	emBits := rsaModBits(nBE) - 1
	emLen := (int(emBits) + 7) / 8
	hLen := h.size()
	if emLen < hLen+2 {
		return false
	}
	em := rsaRSAEP(nBE, eBE, sig)
	if em == nil || len(em) != len(nBE) {
		return false
	}
	if len(em) != emLen {
		return false
	}
	if em[len(em)-1] != 0xbc {
		return false
	}
	dbLen := emLen - hLen - 1
	maskedDB := em[:dbLen]
	hm := em[dbLen : emLen-1]
	// The top 8*emLen - emBits bits of maskedDB must be zero.
	topBits := uint(8*emLen - int(emBits))
	if topBits > 0 {
		mask := byte(0xff) >> topBits
		if maskedDB[0]&^mask != 0 {
			return false
		}
	}
	db := mgf1(h, hm, dbLen)
	for i := 0; i < dbLen; i++ {
		db[i] ^= maskedDB[i]
	}
	if topBits > 0 {
		mask := byte(0xff) >> topBits
		db[0] &= mask
	}
	// DB = 0x00.. || 0x01 || salt: the salt length is whatever follows the
	// single 0x01 separator.
	sep := -1
	for i := 0; i < dbLen; i++ {
		if db[i] != 0x00 {
			if db[i] != 0x01 {
				return false
			}
			sep = i
			break
		}
	}
	if sep < 0 {
		return false
	}
	salt := db[sep+1:]
	// H' = Hash(0x00*8 || mHash || salt) — mHash is the digest the caller
	// already computed, used raw (RFC 8017 §9.1.4 step 8).
	mp := make([]byte, 8+hLen+len(salt))
	copy(mp[8:], digest)
	copy(mp[8+hLen:], salt)
	hPrime := h.hashSum(mp)
	var diff byte
	for i := 0; i < hLen; i++ {
		diff |= hm[i] ^ hPrime[i]
	}
	return diff == 0
}

// mgf1 is MGF1 (RFC 8017 B.2.1) with the given hash.
func mgf1(h hashAlg, seed []byte, length int) []byte {
	out := make([]byte, 0, length+4)
	var counter uint32
	for len(out) < length {
		var c [4]byte
		putBE32(c[:], counter)
		in := append(append([]byte{}, seed...), c[:]...)
		out = append(out, h.hashSum(in)...)
		counter++
	}
	return out[:length]
}

const uint64Size = 8

func putBE32(p []byte, v uint32) {
	p[0] = byte(v >> 24)
	p[1] = byte(v >> 16)
	p[2] = byte(v >> 8)
	p[3] = byte(v)
}

// rsaModBits returns the modulus' bit length.
func rsaModBits(nBE []byte) uint {
	i := 0
	for i < len(nBE) && nBE[i] == 0 {
		i++
	}
	if i >= len(nBE) {
		return 0
	}
	b := nBE[i]
	bit := 0
	for b != 0 {
		bit++
		b >>= 1
	}
	return uint((len(nBE)-i-1)*8 + bit)
}
