// djb ChaCha20 (64-bit counter, 8-byte nonce), Poly1305, and the OpenSSH
// chacha20-poly1305@openssh.com construction. Ported from
// user/src/lib/crypto/chacha20_ssh.zig + ssh_cipher.zig / VSSH SSHCrypto
// and pinned to the same PROTOCOL.chacha20poly1305 vector.
//
// HAZARD (ADR 0025 D4): the IETF draft names K_1/K_2 inverted relative to
// OpenSSH. K_2 is key[0:32] (AEAD); K_1 is key[32:64] (length).

package main

const (
	chachaKeyLen   = 32
	chachaNonceLen = 8
	chachaBlockLen = 64
	polyTagLen     = 16
	sshCipherKey   = 64
	sshLengthLen   = 4
)

func rotl32(v uint32, n uint) uint32 { return v<<n | v>>(32-n) }

func load32LE(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func store32LE(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}

func quarterRound(s *[16]uint32, a, b, c, d int) {
	s[a] += s[b]
	s[d] ^= s[a]
	s[d] = rotl32(s[d], 16)
	s[c] += s[d]
	s[b] ^= s[c]
	s[b] = rotl32(s[b], 12)
	s[a] += s[b]
	s[d] ^= s[a]
	s[d] = rotl32(s[d], 8)
	s[c] += s[d]
	s[b] ^= s[c]
	s[b] = rotl32(s[b], 7)
}

func chachaBlock(key []byte, counter uint64, nonce []byte) [chachaBlockLen]byte {
	var state [16]uint32
	state[0] = 0x61707865
	state[1] = 0x3320646e
	state[2] = 0x79622d32
	state[3] = 0x6b206574
	for i := 0; i < 8; i++ {
		state[4+i] = load32LE(key[i*4:])
	}
	state[12] = uint32(counter)
	state[13] = uint32(counter >> 32)
	state[14] = load32LE(nonce[0:])
	state[15] = load32LE(nonce[4:])
	working := state
	for round := 0; round < 10; round++ {
		quarterRound(&working, 0, 4, 8, 12)
		quarterRound(&working, 1, 5, 9, 13)
		quarterRound(&working, 2, 6, 10, 14)
		quarterRound(&working, 3, 7, 11, 15)
		quarterRound(&working, 0, 5, 10, 15)
		quarterRound(&working, 1, 6, 11, 12)
		quarterRound(&working, 2, 7, 8, 13)
		quarterRound(&working, 3, 4, 9, 14)
	}
	var out [chachaBlockLen]byte
	for k := 0; k < 16; k++ {
		store32LE(out[k*4:], working[k]+state[k])
	}
	return out
}

func chachaXOR(in, key []byte, counter uint64, nonce []byte) []byte {
	out := make([]byte, len(in))
	ctr := counter
	off := 0
	for off < len(in) {
		ks := chachaBlock(key, ctr, nonce)
		ctr++
		take := chachaBlockLen
		if take > len(in)-off {
			take = len(in) - off
		}
		for i := 0; i < take; i++ {
			out[off+i] = in[off+i] ^ ks[i]
		}
		off += take
	}
	return out
}

func poly1305Tag(message, key []byte) [16]byte {
	var r [5]uint32
	r[0] = load32LE(key[0:]) & 0x3ffffff
	r[1] = (load32LE(key[3:]) >> 2) & 0x3ffff03
	r[2] = (load32LE(key[6:]) >> 4) & 0x3ffc0ff
	r[3] = (load32LE(key[9:]) >> 6) & 0x3f03fff
	r[4] = (load32LE(key[12:]) >> 8) & 0x00fffff
	s1 := r[1] * 5
	s2 := r[2] * 5
	s3 := r[3] * 5
	s4 := r[4] * 5
	var h [5]uint32
	off := 0
	for off < len(message) {
		n := 16
		if n > len(message)-off {
			n = len(message) - off
		}
		var blk [16]byte
		copy(blk[:], message[off:off+n])
		if n < 16 {
			blk[n] = 1
		}
		h[0] += load32LE(blk[0:]) & 0x3ffffff
		h[1] += (load32LE(blk[3:]) >> 2) & 0x3ffffff
		h[2] += (load32LE(blk[6:]) >> 4) & 0x3ffffff
		h[3] += (load32LE(blk[9:]) >> 6) & 0x3ffffff
		hi := (load32LE(blk[12:]) >> 8)
		if n == 16 {
			hi |= 1 << 24
		}
		h[4] += hi

		d0 := uint64(h[0])*uint64(r[0]) + uint64(h[1])*uint64(s4) + uint64(h[2])*uint64(s3) + uint64(h[3])*uint64(s2) + uint64(h[4])*uint64(s1)
		d1 := uint64(h[0])*uint64(r[1]) + uint64(h[1])*uint64(r[0]) + uint64(h[2])*uint64(s4) + uint64(h[3])*uint64(s3) + uint64(h[4])*uint64(s2)
		d2 := uint64(h[0])*uint64(r[2]) + uint64(h[1])*uint64(r[1]) + uint64(h[2])*uint64(r[0]) + uint64(h[3])*uint64(s4) + uint64(h[4])*uint64(s3)
		d3 := uint64(h[0])*uint64(r[3]) + uint64(h[1])*uint64(r[2]) + uint64(h[2])*uint64(r[1]) + uint64(h[3])*uint64(r[0]) + uint64(h[4])*uint64(s4)
		d4 := uint64(h[0])*uint64(r[4]) + uint64(h[1])*uint64(r[3]) + uint64(h[2])*uint64(r[2]) + uint64(h[3])*uint64(r[1]) + uint64(h[4])*uint64(r[0])

		c := uint32(d0 >> 26)
		h[0] = uint32(d0) & 0x3ffffff
		d1 += uint64(c)
		c = uint32(d1 >> 26)
		h[1] = uint32(d1) & 0x3ffffff
		d2 += uint64(c)
		c = uint32(d2 >> 26)
		h[2] = uint32(d2) & 0x3ffffff
		d3 += uint64(c)
		c = uint32(d3 >> 26)
		h[3] = uint32(d3) & 0x3ffffff
		d4 += uint64(c)
		c = uint32(d4 >> 26)
		h[4] = uint32(d4) & 0x3ffffff
		h[0] += c * 5
		c = h[0] >> 26
		h[0] &= 0x3ffffff
		h[1] += c
		off += n
	}
	c := h[1] >> 26
	h[1] &= 0x3ffffff
	h[2] += c
	c = h[2] >> 26
	h[2] &= 0x3ffffff
	h[3] += c
	c = h[3] >> 26
	h[3] &= 0x3ffffff
	h[4] += c
	c = h[4] >> 26
	h[4] &= 0x3ffffff
	h[0] += c * 5
	c = h[0] >> 26
	h[0] &= 0x3ffffff
	h[1] += c

	var g [5]uint32
	g[0] = h[0] + 5
	c = g[0] >> 26
	g[0] &= 0x3ffffff
	g[1] = h[1] + c
	c = g[1] >> 26
	g[1] &= 0x3ffffff
	g[2] = h[2] + c
	c = g[2] >> 26
	g[2] &= 0x3ffffff
	g[3] = h[3] + c
	c = g[3] >> 26
	g[3] &= 0x3ffffff
	g[4] = h[4] + c - (1 << 26)
	mask := (g[4] >> 31) - 1
	for i := 0; i < 5; i++ {
		g[i] &= mask
	}
	mask = ^mask
	for i := 0; i < 5; i++ {
		h[i] = (h[i] & mask) | g[i]
	}

	var hh [4]uint32
	hh[0] = (h[0] | (h[1] << 26)) & 0xffffffff
	hh[1] = ((h[1] >> 6) | (h[2] << 20)) & 0xffffffff
	hh[2] = ((h[2] >> 12) | (h[3] << 14)) & 0xffffffff
	hh[3] = ((h[3] >> 18) | (h[4] << 8)) & 0xffffffff
	var carry uint64
	for i := 0; i < 4; i++ {
		carry = uint64(hh[i]) + uint64(load32LE(key[16+i*4:])) + (carry >> 32)
		hh[i] = uint32(carry)
	}
	var out [16]byte
	for i := 0; i < 4; i++ {
		store32LE(out[i*4:], hh[i])
	}
	return out
}

func ctEq16(a, b [16]byte) bool {
	var acc byte
	for i := 0; i < 16; i++ {
		acc |= a[i] ^ b[i]
	}
	return acc == 0
}

func seqNonce(seq uint64) [8]byte {
	return [8]byte{
		byte(seq >> 56), byte(seq >> 48), byte(seq >> 40), byte(seq >> 32),
		byte(seq >> 24), byte(seq >> 16), byte(seq >> 8), byte(seq),
	}
}

type sshCipher struct {
	key [sshCipherKey]byte
}

func (c *sshCipher) polyKey(seq uint64) [32]byte {
	nonce := seqNonce(seq)
	block := chachaBlock(c.key[0:32], 0, nonce[:])
	var out [32]byte
	copy(out[:], block[:32])
	return out
}

func (c *sshCipher) decryptLength(enc []byte, seq uint64) uint32 {
	nonce := seqNonce(seq)
	plain := chachaXOR(enc[:4], c.key[32:64], 0, nonce[:])
	return uint32(plain[0])<<24 | uint32(plain[1])<<16 | uint32(plain[2])<<8 | uint32(plain[3])
}

func (c *sshCipher) seal(plaintext []byte, seq uint64) (ct, tag []byte) {
	nonce := seqNonce(seq)
	ct = make([]byte, len(plaintext))
	encLen := chachaXOR(plaintext[:4], c.key[32:64], 0, nonce[:])
	copy(ct[:4], encLen)
	encBody := chachaXOR(plaintext[4:], c.key[0:32], 1, nonce[:])
	copy(ct[4:], encBody)
	pkey := c.polyKey(seq)
	t := poly1305Tag(ct, pkey[:])
	tag = t[:]
	return ct, append([]byte(nil), tag...)
}

func (c *sshCipher) open(ciphertext, tag []byte, seq uint64) []byte {
	if len(ciphertext) < 4 || len(tag) != 16 {
		return nil
	}
	pkey := c.polyKey(seq)
	expect := poly1305Tag(ciphertext, pkey[:])
	var got [16]byte
	copy(got[:], tag)
	if !ctEq16(expect, got) {
		return nil
	}
	nonce := seqNonce(seq)
	plainLen := chachaXOR(ciphertext[:4], c.key[32:64], 0, nonce[:])
	plainBody := chachaXOR(ciphertext[4:], c.key[0:32], 1, nonce[:])
	return append(plainLen, plainBody...)
}
