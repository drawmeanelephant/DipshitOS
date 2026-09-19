// AES-128 and GCM pins: FIPS 197's worked example, RFC 8439 §5.2's AES-GCM
// vector, NIST GCM test cases 1-2, tamper/round-trip negatives, and a
// host-stdlib cross-check over random lengths.

package tls

import (
	"bytes"
	"crypto/aes"
	stdcipher "crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"testing"
)

func TestAES128FIPS197Example(t *testing.T) {
	// FIPS 197 §C.1: key 000102..0f, plaintext 00112233445566778899aabbccddeeff,
	// ciphertext 69c4e0d86a7b0430d8cdb78070b4c55a.
	key, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	pt, _ := hex.DecodeString("00112233445566778899aabbccddeeff")
	want, _ := hex.DecodeString("69c4e0d86a7b0430d8cdb78070b4c55a")
	a, err := newAES128(key)
	if err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 16)
	a.encryptBlock(got, pt)
	if !bytes.Equal(got, want) {
		t.Fatalf("fips197 mismatch: got %x", got)
	}
}

func TestGCMSBoxAnchors(t *testing.T) {
	// The construction asserts at init; re-check the anchors for the report.
	if aesSbox[0x00] != 0x63 || aesSbox[0x53] != 0xed {
		t.Fatal("sbox anchors broken")
	}
}

func TestGCMRFC8439Vector(t *testing.T) {
	// RFC 8439 §5.2.
	key, _ := hex.DecodeString("feffe9928665731c6d6a8f9467308308")
	nonce, _ := hex.DecodeString("cafebabefacedbaddecaf888")
	pt, _ := hex.DecodeString("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
	// The §5.2 vector includes AAD "feedfacedeadbeeffeedfacedeadbeefabaddad2".
	aad, _ := hex.DecodeString("feedfacedeadbeeffeedfacedeadbeefabaddad2")
	wantCT, _ := hex.DecodeString("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091")
	// Double-confirmed value: my implementation and the FIPS-validated host
	// stdlib agree byte-for-byte on this input (the first draft of this test
	// carried a remembered tag that disagreed with both — the ADR 0029 D2
	// lesson in one line).
	wantTag, _ := hex.DecodeString("5bc94fbc3221a5db94fae95ae7121a47")
	a, err := newAES128(key)
	if err != nil {
		t.Fatal(err)
	}
	out := make([]byte, len(pt)+16)
	if err := gcmSeal(a, out, pt, aad, nonce); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out[:len(pt)], wantCT) {
		t.Fatalf("gcm ct mismatch: got %x", out[:len(pt)])
	}
	if !bytes.Equal(out[len(pt):], wantTag) {
		t.Fatalf("gcm tag mismatch: got %x", out[len(pt):])
	}
	back := make([]byte, len(pt))
	if err := gcmOpen(a, back, out, aad, nonce); err != nil {
		t.Fatalf("gcm open failed: %v", err)
	}
	if !bytes.Equal(back, pt) {
		t.Fatal("gcm round-trip mismatch")
	}
}

func TestGCMNISTCases1And2(t *testing.T) {
	// NIST SP 800-38D GCM Test Case 1 and 2 (empty plaintext / no AAD).
	key, _ := hex.DecodeString("00000000000000000000000000000000")
	a, _ := newAES128(key)

	// Case 1: empty everything; tag = 58e2fccefa7e3061367f1d57a4e7455a.
	nonce, _ := hex.DecodeString("000000000000000000000000")
	out := make([]byte, 16)
	if err := gcmSeal(a, out, nil, nil, nonce); err != nil {
		t.Fatal(err)
	}
	want, _ := hex.DecodeString("58e2fccefa7e3061367f1d57a4e7455a")
	if !bytes.Equal(out, want) {
		t.Fatalf("nist case1 tag mismatch: %x", out)
	}

	// Case 2: one zero block of plaintext, no AAD;
	// ct 0388dace60b6a392f328c2b971b2fe78, tag ab6e47d42cec13bdf53a67b21257bddf.
	pt := make([]byte, 16)
	out2 := make([]byte, 32)
	if err := gcmSeal(a, out2, pt, nil, nonce); err != nil {
		t.Fatal(err)
	}
	wantCT, _ := hex.DecodeString("0388dace60b6a392f328c2b971b2fe78")
	if !bytes.Equal(out2[:16], wantCT) {
		t.Fatalf("nist case2 ct mismatch: %x", out2[:16])
	}
	wantTag, _ := hex.DecodeString("ab6e47d42cec13bdf53a67b21257bddf")
	if !bytes.Equal(out2[16:], wantTag) {
		t.Fatalf("nist case2 tag mismatch: %x", out2[16:])
	}
}

func TestGCMAgainstHostStdlib(t *testing.T) {
	for i := 0; i < 60; i++ {
		key := make([]byte, 16)
		nonce := make([]byte, 12)
		aadLen := i % 40
		ptLen := (i * 137) % 3000
		aad := make([]byte, aadLen)
		pt := make([]byte, ptLen)
		rand.Read(key)
		rand.Read(nonce)
		rand.Read(aad)
		rand.Read(pt)

		mine, err := newAES128(key)
		if err != nil {
			t.Fatal(err)
		}
		mineOut := make([]byte, len(pt)+16)
		if err := gcmSeal(mine, mineOut, pt, aad, nonce); err != nil {
			t.Fatal(err)
		}

		block, err := aes.NewCipher(key)
		if err != nil {
			t.Fatal(err)
		}
		stdGCM, err := stdcipher.NewGCM(block)
		if err != nil {
			t.Fatal(err)
		}
		stdOut := stdGCM.Seal(nil, nonce, pt, aad)
		if !bytes.Equal(mineOut, stdOut) {
			t.Fatalf("gcm mismatch (ptlen %d, aadlen %d)", ptLen, aadLen)
		}

		// Tamper one ciphertext bit: open must fail.
		mineOut[0] ^= 0x01
		if err := gcmOpen(mine, make([]byte, len(pt)), mineOut, aad, nonce); err == nil {
			t.Fatal("tampered ciphertext accepted")
		}
	}
}

func TestGCMOpenNeverOutputsOnTagFailure(t *testing.T) {
	key := bytes.Repeat([]byte{7}, 16)
	nonce := bytes.Repeat([]byte{9}, 12)
	a, _ := newAES128(key)
	pt := bytes.Repeat([]byte{0xAB}, 64)
	out := make([]byte, len(pt)+16)
	if err := gcmSeal(a, out, pt, nil, nonce); err != nil {
		t.Fatal(err)
	}
	out[3] ^= 0x40
	sink := make([]byte, len(pt))
	if err := gcmOpen(a, sink, out, nil, nonce); err == nil {
		t.Fatal("tampered record accepted")
	}
	for _, b := range sink {
		if b != 0 {
			t.Fatal("plaintext written despite tag failure")
		}
	}
}
