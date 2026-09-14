// AES / AES-GCM vector generator for the in-tree TLS 1.3 client.
//
// Produces expected outputs using Go's independent implementation
// (crypto/aes + cipher.NewGCM, Go 1.27.1) for the in-tree Zig code in
// user/src/lib/crypto/aes.zig and gcm.zig.
//
// Two published-value assertions are built in and abort the run if Go
// disagrees, so the generator is cross-checked against FIPS 197 and the
// NIST GCM specification before any value is pinned:
//   - FIPS 197 C.1/C.3 AES-ECB known-answer tests.
//   - NIST GCM test cases 1 and 2 (McGrew & Viega, "The Galois/Counter Mode
//     of Operation", test case 1: T = 58e2fccefa7e3061367f1d57a4e7455a;
//     test case 2: T = ab6e47d42cec13bdf53a67b21257bddf).
//
// The ECB vectors are additionally cross-checked with `openssl enc
// -aes-128-ecb` by the driver script.
//
// Usage: go run gen_aesgcm.go > aes-vectors.json
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
)

type ecbVec struct {
	Name string `json:"name"`
	Key  string `json:"key"`
	PT   string `json:"pt"`
	CT   string `json:"ct"`
}

type gcmVec struct {
	Name  string `json:"name"`
	Key   string `json:"key"`
	Nonce string `json:"nonce"`
	AAD   string `json:"aad"`
	PT    string `json:"pt"`
	CT    string `json:"ct"`
	Tag   string `json:"tag"`
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func rep(b byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = b
	}
	return out
}

func seq(start, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = byte(start + i)
	}
	return out
}

func fill(n int, f func(int) byte) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = f(i)
	}
	return out
}

func hx(b []byte) string { return hex.EncodeToString(b) }

func main() {
	ecb := []ecbVec{}
	for _, tc := range []struct{ name, key, pt string }{
		{"fips197-C1-aes128", "000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff"},
		{"fips197-C3-aes256", "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "00112233445566778899aabbccddeeff"},
		{"aes128-zero", "00000000000000000000000000000000", "00000000000000000000000000000000"},
		{"aes128-all-ff", "ffffffffffffffffffffffffffffffff", "ffffffffffffffffffffffffffffffff"},
		{"aes128-mixed", hx(seq(0x10, 16)), hx(seq(0x40, 16))},
		{"aes128-ascii", "00000000000000000000000000000000", hx([]byte("abcdefghijklmnop"))},
		{"aes256-mixed", hx(seq(0x20, 32)), hx(seq(0x50, 16))},
		{"aes256-0102", hx(rep(0x01, 32)), hx(rep(0x02, 16))},
	} {
		c, err := aes.NewCipher(mustHex(tc.key))
		if err != nil {
			panic(err)
		}
		out := make([]byte, 16)
		c.Encrypt(out, mustHex(tc.pt))
		ecb = append(ecb, ecbVec{Name: tc.name, Key: tc.key, PT: tc.pt, CT: hx(out)})
	}

	// Published-value assertions (FIPS 197 C.1/C.3).
	want := map[string]string{
		"fips197-C1-aes128": "69c4e0d86a7b0430d8cdb78070b4c55a",
		"fips197-C3-aes256": "8ea2b7ca516745bfeafc49904b496089",
	}
	for _, v := range ecb {
		if w, ok := want[v.Name]; ok && w != v.CT {
			fmt.Fprintf(os.Stderr, "FATAL: %s: got %s want %s\n", v.Name, v.CT, w)
			os.Exit(1)
		}
	}

	type gcase struct {
		name  string
		key   []byte
		nonce []byte
		aad   []byte
		pt    []byte
	}
	k0 := rep(0x00, 16)
	k0_256 := rep(0x00, 32)
	n0 := rep(0x00, 12)
	kA := seq(0x30, 16)
	kB := seq(0x70, 32)
	nA := seq(0x90, 12)

	cases := []gcase{
		// NIST GCM test cases 1 and 2 (all-zero key, all-zero 96-bit IV).
		{"nist-gcm-tc1", k0, n0, nil, nil},
		{"nist-gcm-tc2", k0, n0, nil, rep(0x00, 16)},
		// Synthetic coverage.
		{"gcm128-empty-pt-60aad", kA, nA, seq(0xa0, 60), nil},
		{"gcm128-pt15", kA, nA, nil, seq(0x01, 15)},
		{"gcm128-pt16", kA, nA, nil, seq(0x01, 16)},
		{"gcm128-pt17", kA, nA, nil, seq(0x01, 17)},
		{"gcm128-aad-only", kA, nA, seq(0x01, 32), nil},
		{"gcm128-pt1k", kA, nA, seq(0x02, 16), fill(1024, func(i int) byte { return byte(i) })},
		{"gcm128-pt1k-aad60", kA, nA, seq(0x03, 60), fill(1024, func(i int) byte { return byte(i * 7) })},
		{"gcm128-pt255", kA, nA, seq(0x08, 8), seq(0x09, 255)},
		{"gcm256-nist-tc-empty", k0_256, n0, nil, nil},
		{"gcm256-nist-tc-1block", k0_256, n0, nil, rep(0x00, 16)},
		{"gcm256-pt17-aad16", kB, nA, seq(0x04, 16), seq(0x05, 17)},
		{"gcm256-pt1k", kB, nA, nil, fill(1024, func(i int) byte { return byte(i * 3) })},
		{"gcm256-pt255", kB, nA, seq(0x06, 8), seq(0x07, 255)},
	}

	gcm := []gcmVec{}
	for _, tc := range cases {
		blk, err := aes.NewCipher(tc.key)
		if err != nil {
			panic(err)
		}
		aead, err := cipher.NewGCM(blk)
		if err != nil {
			panic(err)
		}
		sealed := aead.Seal(nil, tc.nonce, tc.pt, tc.aad)
		ct := sealed[:len(sealed)-16]
		tag := sealed[len(sealed)-16:]
		back, err := aead.Open(nil, tc.nonce, sealed, tc.aad)
		if err != nil || string(back) != string(tc.pt) {
			panic("round trip failed for " + tc.name)
		}
		gcm = append(gcm, gcmVec{
			Name: tc.name, Key: hx(tc.key), Nonce: hx(tc.nonce),
			AAD: hx(tc.aad), PT: hx(tc.pt), CT: hx(ct), Tag: hx(tag),
		})
	}

	// Published-value assertions (NIST GCM test cases 1 and 2).
	gwant := map[string]string{
		"nist-gcm-tc1": "58e2fccefa7e3061367f1d57a4e7455a",
		"nist-gcm-tc2": "ab6e47d42cec13bdf53a67b21257bddf",
	}
	for _, v := range gcm {
		if w, ok := gwant[v.Name]; ok && w != v.Tag {
			fmt.Fprintf(os.Stderr, "FATAL: %s: got tag %s want %s\n", v.Name, v.Tag, w)
			os.Exit(1)
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(map[string]any{
		"producer":           "go1.27.1 crypto/aes + cipher.NewGCM",
		"asserted_published": []string{"FIPS 197 C.1", "FIPS 197 C.3", "NIST GCM test case 1", "NIST GCM test case 2"},
		"ecb":                ecb,
		"gcm":                gcm,
	}); err != nil {
		panic(err)
	}
	fmt.Fprintf(os.Stderr, "OK: %d ecb + %d gcm vectors; published-value assertions passed\n", len(ecb), len(gcm))
}
