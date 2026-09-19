package main

func hashString(h *sha256Digest, s []byte) {
	var lenBuf [4]byte
	n := uint32(len(s))
	lenBuf[0] = byte(n >> 24)
	lenBuf[1] = byte(n >> 16)
	lenBuf[2] = byte(n >> 8)
	lenBuf[3] = byte(n)
	h.write(lenBuf[:])
	h.write(s)
}

func exchangeHash(vc, vs, ic, isI, ks, qc, qs, kMpint []byte) [32]byte {
	h := sha256Init()
	hashString(&h, vc)
	hashString(&h, vs)
	hashString(&h, ic)
	hashString(&h, isI)
	hashString(&h, ks)
	hashString(&h, qc)
	hashString(&h, qs)
	h.write(kMpint)
	return h.sum()
}

func deriveKey(length int, kMpint, h []byte, letter byte, sessionID []byte) []byte {
	out := make([]byte, 0, length)
	first := sha256Init()
	first.write(kMpint)
	first.write(h)
	first.write([]byte{letter})
	first.write(sessionID)
	sum := first.sum()
	out = append(out, sum[:]...)
	for len(out) < length {
		next := sha256Init()
		next.write(kMpint)
		next.write(h)
		next.write(out)
		s := next.sum()
		out = append(out, s[:]...)
	}
	return out[:length]
}

func mpint(raw []byte) []byte {
	start := 0
	for start < len(raw) && raw[start] == 0 {
		start++
	}
	body := append([]byte(nil), raw[start:]...)
	if len(body) > 0 && body[0]&0x80 != 0 {
		body = append([]byte{0}, body...)
	}
	var w sshWriter
	w.str(body)
	return w.b
}
