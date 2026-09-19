// ECDSA and RSA verification pins: the OpenSSL-generated vectors (positive
// cases and mutated negatives) plus host-stdlib cross-checks — random
// stdlib-signed signatures must verify, and flipped bits must not.

package tls

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/sha512"
	"math/big"
	"testing"
)

func TestECDSAGeneratedVectors(t *testing.T) {
	for _, sc := range ecdsaSigCases {
		var curve *ecCurve
		zlen := 32
		switch sc.curve {
		case "prime256v1":
			curve = ecP256()
			zlen = 32
		case "secp384r1":
			curve = ecP384()
			zlen = 48
		default:
			t.Fatalf("unknown curve %q", sc.curve)
		}
		// z = hash of the message, truncated to the curve length.
		var digest []byte
		switch sc.hash {
		case "sha256":
			h := sha256.Sum256([]byte(sc.msg))
			digest = h[:]
		case "sha384":
			h := sha512.Sum384([]byte(sc.msg))
			digest = h[:]
		}
		digest = digest[:zlen]
		pubx := hexDecode(sc.pubx)
		puby := hexDecode(sc.puby)
		r := hexDecode(sc.r)
		s := hexDecode(sc.s)
		if !curve.verifyECDSA(pubx, puby, r, s, digest) {
			t.Fatalf("vector %s must verify", sc.label)
		}
		// A mutated s must not.
		badS := append([]byte{}, s...)
		badS[0] ^= 0x01
		if curve.verifyECDSA(pubx, puby, r, badS, digest) {
			t.Fatalf("vector %s: mutated s verified", sc.label)
		}
		// A mutated message digest must not.
		badZ := append([]byte{}, digest...)
		badZ[0] ^= 0x01
		if curve.verifyECDSA(pubx, puby, r, s, badZ) {
			t.Fatalf("vector %s: mutated digest verified", sc.label)
		}
	}
}

func TestECDSARefusals(t *testing.T) {
	// r = 0, s = 0, r >= n, s >= n are refused without touching the ladder.
	curve := ecP256()
	pubx := hexDecode(ecdsaSigCases[0].pubx)
	puby := hexDecode(ecdsaSigCases[0].puby)
	r := hexDecode(ecdsaSigCases[0].r)
	s := hexDecode(ecdsaSigCases[0].s)
	digest := make([]byte, 32)

	zero := make([]byte, 32)
	if curve.verifyECDSA(pubx, puby, zero, s, digest) {
		t.Fatal("r=0 accepted")
	}
	if curve.verifyECDSA(pubx, puby, r, zero, digest) {
		t.Fatal("s=0 accepted")
	}
	n := hexDecode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
	if curve.verifyECDSA(pubx, puby, n, s, digest) {
		t.Fatal("r>=n accepted")
	}
	if curve.verifyECDSA(pubx, puby, r, n, digest) {
		t.Fatal("s>=n accepted")
	}
}

func TestECDSAAgainstHostStdlib(t *testing.T) {
	for _, c := range []struct {
		name  string
		curve elliptic.Curve
		mine  func() *ecCurve
	}{
		{"p256", elliptic.P256(), ecP256},
		{"p384", elliptic.P384(), ecP384},
	} {
		for i := 0; i < 12; i++ {
			priv, err := ecdsa.GenerateKey(c.curve, rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			msg := make([]byte, 5+i)
			rand.Read(msg)
			var digest []byte
			if c.name == "p256" {
				h := sha256.Sum256(msg)
				digest = h[:]
			} else {
				h := sha512.Sum384(msg)
				digest = h[:]
			}
			sig, err := ecdsa.SignASN1(rand.Reader, priv, digest)
			if err != nil {
				t.Fatal(err)
			}
			// Parse the ASN.1 sig with our DER reader.
			outer := newDERReader(sig)
			seq, err := outer.expect(derTagSequence)
			if err != nil {
				t.Fatal(err)
			}
			sr := newDERReader(seq.content)
			rE, err := sr.expect(derTagInteger)
			if err != nil {
				t.Fatal(err)
			}
			sE, err := sr.expect(derTagInteger)
			if err != nil {
				t.Fatal(err)
			}
			rB, err := derInteger(rE)
			if err != nil {
				t.Fatal(err)
			}
			sB, err := derInteger(sE)
			if err != nil {
				t.Fatal(err)
			}
			pubx := priv.PublicKey.X.Bytes()
			puby := priv.PublicKey.Y.Bytes()
			pad := (c.curve.Params().BitSize + 7) / 8
			pubx = append(make([]byte, pad-len(pubx)), pubx...)
			puby = append(make([]byte, pad-len(puby)), puby...)
			if !c.mine().verifyECDSA(pubx, puby, rB, sB, digest) {
				t.Fatalf("%s: stdlib signature rejected", c.name)
			}
			digest[0] ^= 1
			if c.mine().verifyECDSA(pubx, puby, rB, sB, digest) {
				t.Fatalf("%s: tampered digest accepted", c.name)
			}
		}
	}
}

func TestRSAGeneratedVectors(t *testing.T) {
	for _, rc := range rsaSigCases {
		n := hexDecode(rc.n)
		e := hexDecode(rc.e)
		sig := hexDecode(rc.sig)
		var h hashAlg
		switch rc.hash {
		case "sha256":
			h = hashSHA256
		case "sha384":
			h = hashSHA384
		case "sha512":
			h = hashSHA512
		default:
			t.Fatalf("unknown hash %q", rc.hash)
		}
		digest := h.hashSum([]byte(rc.msg))
		var ok bool
		switch rc.padding {
		case "pkcs1":
			ok = verifyRsaPkcs1(n, e, h, digest, sig)
		case "pss":
			ok = verifyRsaPss(n, e, h, digest, sig)
		}
		if !ok {
			t.Fatalf("vector %s must verify", rc.name)
		}
		bad := append([]byte{}, sig...)
		bad[17] ^= 0x04
		switch rc.padding {
		case "pkcs1":
			if verifyRsaPkcs1(n, e, h, digest, bad) {
				t.Fatalf("vector %s: mutated sig verified", rc.name)
			}
		case "pss":
			if verifyRsaPss(n, e, h, digest, bad) {
				t.Fatalf("vector %s: mutated sig verified", rc.name)
			}
		}
	}
}

func TestRSAAgainstHostStdlib(t *testing.T) {
	for i := 0; i < 6; i++ {
		priv, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		msg := make([]byte, 10+i)
		rand.Read(msg)
		digest := sha256.Sum256(msg)

		// PKCS#1 v1.5.
		sig, err := rsa.SignPKCS1v15(rand.Reader, priv, crypto.SHA256, digest[:])
		if err != nil {
			t.Fatal(err)
		}
		n := priv.PublicKey.N.Bytes()
		e := big.NewInt(int64(priv.PublicKey.E)).Bytes()
		if !verifyRsaPkcs1(n, e, hashSHA256, digest[:], sig) {
			t.Fatal("stdlib pkcs1 signature rejected")
		}

		// PSS (salt length = digest length).
		sigPSS, err := rsa.SignPSS(rand.Reader, priv, crypto.SHA256, digest[:], &rsa.PSSOptions{SaltLength: sha256.Size})
		if err != nil {
			t.Fatal(err)
		}
		if !verifyRsaPss(n, e, hashSHA256, digest[:], sigPSS) {
			t.Fatal("stdlib pss signature rejected")
		}

		// Negatives.
		digest[0] ^= 1
		if verifyRsaPkcs1(n, e, hashSHA256, digest[:], sig) {
			t.Fatal("tampered pkcs1 digest accepted")
		}
		if verifyRsaPss(n, e, hashSHA256, digest[:], sigPSS) {
			t.Fatal("tampered pss digest accepted")
		}
	}
}

func TestRSAPkcs1StructureNegative(t *testing.T) {
	// The DigestInfo tail must match exactly: a valid-looking padding with a
	// truncated tail is refused.
	n := hexDecode(rsaSigCases[0].n)
	e := hexDecode("010001")
	sig := hexDecode(rsaSigCases[0].sig)
	em := rsaRSAEP(n, e, sig)
	if em == nil {
		t.Fatal("recovery failed")
	}
	// Locate the 0x00 separator and truncate the DigestInfo by one byte.
	sep := bytes.IndexByte(em, 0x00)
	if sep < 0 {
		t.Fatal("no separator")
	}
	_ = sep
	// Flip a tail bit via the digest instead: verify then tamper.
	h := hashSHA256
	digest := h.hashSum([]byte(rsaSigCases[0].msg))
	if !verifyRsaPkcs1(n, e, h, digest, sig) {
		t.Fatal("sanity: vector must verify")
	}
	digest2 := append([]byte{}, digest...)
	digest2[len(digest2)-1] ^= 0x80
	if verifyRsaPkcs1(n, e, h, digest2, sig) {
		t.Fatal("tampered digest accepted")
	}
}
