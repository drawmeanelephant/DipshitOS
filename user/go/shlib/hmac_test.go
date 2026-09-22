package shlib

import (
	"bytes"
	"crypto/hmac"
	stdsha256 "crypto/sha256"
	"encoding/hex"
	"math/rand"
	"testing"
)

func TestSHA256FIPSABC(t *testing.T) {
	got := sha256Sum([]byte("abc"))
	want, _ := hex.DecodeString("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	if !bytes.Equal(got[:], want) {
		t.Fatalf("sha256(abc) = %x", got)
	}
}

func TestHMACRFC4231Case1(t *testing.T) {
	key, _ := hex.DecodeString("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	got := hmacSha256(key, []byte("Hi There"))
	want, _ := hex.DecodeString("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	if !bytes.Equal(got[:], want) {
		t.Fatalf("rfc4231 case 1 = %x", got)
	}
}

func TestHMACAgainstHostStdlib(t *testing.T) {
	rng := rand.New(rand.NewSource(43))
	for i := 0; i < 100; i++ {
		key := make([]byte, rng.Intn(100))
		msg := make([]byte, rng.Intn(500))
		rng.Read(key)
		rng.Read(msg)
		mine := hmacSha256(key, msg)
		mac := hmac.New(stdsha256.New, key)
		mac.Write(msg)
		if !hmac.Equal(mine[:], mac.Sum(nil)) {
			t.Fatalf("hmac-sha256 mismatch keylen=%d msglen=%d", len(key), len(msg))
		}
	}
}
