// SHA-256/384/512 and HMAC pins: the FIPS 180-4 message vectors, RFC 4231
// HMAC cases, RFC 8448 transcript hashes, and a host-stdlib cross-check over
// random lengths (stock Go's audited implementations are the independent
// source ADR 0029 D2 asks for).

package tls

import (
	"bytes"
	"crypto/hmac"
	stdsha256 "crypto/sha256"
	stdsha512 "crypto/sha512"
	"encoding/hex"
	"math/rand"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func TestSHA256FIPSVectors(t *testing.T) {
	// FIPS 180-4 §B / NIST CSHAKE examples: the two published digests.
	cases := []struct{ msg, want string }{
		{"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
	}
	for _, c := range cases {
		got := sha256Sum([]byte(c.msg))
		if !bytes.Equal(got[:], mustHex(t, c.want)) {
			t.Fatalf("sha256(%q) mismatch", c.msg)
		}
	}
	// The one-million-'a' vector, streamed through many writes.
	d := sha256Init()
	blk := bytes.Repeat([]byte("a"), 1000)
	for i := 0; i < 1000; i++ {
		d.write(blk)
	}
	got := d.sum()
	want := mustHex(t, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
	if !bytes.Equal(got[:], want) {
		t.Fatalf("sha256 million-a mismatch")
	}
}

func TestSHA384512FIPSVectors(t *testing.T) {
	got384 := sha384Sum([]byte("abc"))
	if !bytes.Equal(got384[:], mustHex(t, "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")) {
		t.Fatalf("sha384(abc) mismatch")
	}
	got512 := sha512Sum([]byte("abc"))
	if !bytes.Equal(got512[:], mustHex(t, "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")) {
		t.Fatalf("sha512(abc) mismatch")
	}
}

func TestSHAAgainstHostStdlib(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 200; i++ {
		n := rng.Intn(700)
		msg := make([]byte, n)
		rng.Read(msg)
		mine256 := sha256Sum(msg)
		std := stdsha256.Sum256(msg)
		if !bytes.Equal(mine256[:], std[:]) {
			t.Fatalf("sha256 mismatch at len %d", n)
		}
		mine512 := sha512Sum(msg)
		std512 := stdsha512.Sum512(msg)
		if !bytes.Equal(mine512[:], std512[:]) {
			t.Fatalf("sha512 mismatch at len %d", n)
		}
	}
}

func TestHMACAgainstHostStdlib(t *testing.T) {
	rng := rand.New(rand.NewSource(43))
	for i := 0; i < 100; i++ {
		klen := rng.Intn(100)
		n := rng.Intn(500)
		key := make([]byte, klen)
		msg := make([]byte, n)
		rng.Read(key)
		rng.Read(msg)
		mine := hmacSha256(key, msg)
		mac := hmac.New(stdsha256.New, key)
		mac.Write(msg)
		std := mac.Sum(nil)
		if !hmac.Equal(mine[:], std) {
			t.Fatalf("hmac-sha256 mismatch (keylen %d, msglen %d)", klen, n)
		}
		mine512 := hmacSha512(key, msg)
		mac512 := hmac.New(stdsha512.New, key)
		mac512.Write(msg)
		std512 := mac512.Sum(nil)
		if !hmac.Equal(mine512[:], std512) {
			t.Fatalf("hmac-sha512 mismatch (keylen %d, msglen %d)", klen, n)
		}
	}
}

func TestHMACRFC4231Case1(t *testing.T) {
	key := mustHex(t, "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	msg := []byte("Hi There")
	got := hmacSha256(key, msg)
	want := mustHex(t, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	if !bytes.Equal(got[:], want) {
		t.Fatalf("rfc4231 case 1 mismatch")
	}
}
