// HKDF (RFC 5869) and the TLS 1.3 key schedule (RFC 8446 §7.1) over SHA-256.
//
// The one suite this client implements is TLS_AES_128_GCM_SHA256 (mandatory
// to implement, RFC 8446 §9.1; the same single-suite scope as the Zig client
// in user/src/lib/tls). Pinned to RFC 5869's published vectors and the RFC
// 8448 §3 intermediate values in vectors_rfc8448_test.go — every secret, key,
// IV and Finished key the schedule produces has a published expected value.

package tls

// hkdfExtract is HKDF-Extract (RFC 5869 §2.2): PRK = HMAC-Hash(salt, IKM).
func hkdfExtract(salt, ikm []byte) [32]byte {
	return hmacSha256(salt, ikm)
}

// hkdfExpand is HKDF-Expand (RFC 5869 §2.3): T(i) = HMAC-Hash(PRK,
// T(i-1) || info || i), OKM = T(1)..T(N). okmLen <= 255*HashLen is a hard RFC
// bound; this refuses more (never truncates).
func hkdfExpand(prk, info []byte, okmLen int) ([]byte, error) {
	if okmLen <= 0 || okmLen > 255*32 {
		return nil, errHKDFLength
	}
	out := make([]byte, 0, okmLen)
	var t []byte
	for counter := byte(1); len(out) < okmLen; counter++ {
		msg := make([]byte, 0, len(t)+len(info)+1)
		msg = append(msg, t...)
		msg = append(msg, info...)
		msg = append(msg, counter)
		block := hmacSha256(prk, msg)
		out = append(out, block[:]...)
		t = block[:]
	}
	return out[:okmLen], nil
}

// The TLS 1.3 label prefix (RFC 8446 §7.1).
const hkdfLabelPrefix = "tls13 "

// expandLabel is HKDF-Expand-Label(Secret, Label, Context, Length): the
// HkdfLabel structure { uint16 length; opaque label<7..255>;
// opaque context<0..255> } with the "tls13 " prefix on the label.
func expandLabel(secret []byte, label, context string, length int) []byte {
	full := len(hkdfLabelPrefix) + len(label)
	if full > 255 || len(context) > 255 {
		panic("tls: expandLabel over 255-byte bound")
	}
	info := make([]byte, 0, 2+1+full+1+len(context))
	info = append(info, byte(length>>8), byte(length))
	info = append(info, byte(full))
	info = append(info, hkdfLabelPrefix...)
	info = append(info, label...)
	info = append(info, byte(len(context)))
	info = append(info, context...)
	okm, err := hkdfExpand(secret, info, length)
	if err != nil {
		panic("tls: expandLabel length bound")
	}
	return okm
}

// deriveSecret is Derive-Secret(Secret, Label, Messages) where the caller
// passes the transcript hash of Messages (RFC 8446 §7.1).
func deriveSecret(secret [32]byte, label string, transcriptHash [32]byte) [32]byte {
	var out [32]byte
	okm := expandLabel(secret[:], label, string(transcriptHash[:]), 32)
	copy(out[:], okm)
	return out
}

// trafficKey derives the AEAD key for a traffic secret ("tls13 key").
func trafficKey(secret [32]byte) [16]byte {
	var out [16]byte
	copy(out[:], expandLabel(secret[:], "key", "", 16))
	return out
}

// trafficIv derives the static per-record IV for a traffic secret ("tls13 iv").
func trafficIv(secret [32]byte) [12]byte {
	var out [12]byte
	copy(out[:], expandLabel(secret[:], "iv", "", 12))
	return out
}

// finishedKey derives the Finished MAC key for a traffic secret.
func finishedKey(secret [32]byte) [32]byte {
	var out [32]byte
	copy(out[:], expandLabel(secret[:], "finished", "", 32))
	return out
}
