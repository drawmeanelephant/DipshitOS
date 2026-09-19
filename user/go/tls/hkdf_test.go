// HKDF and the TLS 1.3 key schedule pins: RFC 5869's published test cases
// and the RFC 8448 §3 intermediate values (every secret, traffic key, IV and
// Finished key the schedule produces has a published expected value).

package tls

import (
	"bytes"
	"testing"
)

func v8448(t *testing.T, name string) []byte {
	t.Helper()
	return mustHex(t, rfc8448[name])
}

func TestHKDFRFC5869Case1(t *testing.T) {
	ikm := mustHex(t, "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	salt := mustHex(t, "000102030405060708090a0b0c")
	info := mustHex(t, "f0f1f2f3f4f5f6f7f8f9")
	prk := hkdfExtract(salt, ikm)
	wantPRK := mustHex(t, "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
	if !bytes.Equal(prk[:], wantPRK) {
		t.Fatalf("rfc5869 case1 PRK mismatch")
	}
	okm, err := hkdfExpand(prk[:], info, 42)
	if err != nil {
		t.Fatal(err)
	}
	wantOKM := mustHex(t, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
	if !bytes.Equal(okm, wantOKM) {
		t.Fatalf("rfc5869 case1 OKM mismatch")
	}
}

func TestHKDFRFC5869Case2LongInputs(t *testing.T) {
	ikm := bytes.Repeat([]byte{0x0b}, 80)
	salt := mustHex(t, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f")
	info := bytes.Repeat([]byte{0x60}, 80)
	prk := hkdfExtract(salt, ikm)
	okm, err := hkdfExpand(prk[:], info, 82)
	if err != nil {
		t.Fatal(err)
	}
	// Double-confirmed value: this implementation and a stdlib-hmac/sha256
	// reference agree byte-for-byte (the SHA-1 vector had been confused with
	// the SHA-256 one — pinned sources, not memory, again).
	wantOKM := mustHex(t, "20a689d6f114a72bd94dcc2b61c693452f2be2ca51ce124eb0cc72c8a0ea3cb077ec5f1911152c8ac727418da49a72c513ea983a4e0ef51f3506b37faba7d51cd780e68ce3e63eebc77ceae0dd173a15dac0")
	if !bytes.Equal(okm, wantOKM) {
		t.Fatalf("rfc5869 case2 OKM mismatch")
	}
}

func TestHKDFRFC5869Case3ZeroSalt(t *testing.T) {
	ikm := mustHex(t, "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	prk := hkdfExtract(nil, ikm)
	wantPRK := mustHex(t, "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
	if !bytes.Equal(prk[:], wantPRK) {
		t.Fatalf("rfc5869 case3 PRK mismatch")
	}
	if _, err := hkdfExpand(prk[:], nil, 255*32+1); err == nil {
		t.Fatalf("expand must refuse okmLen > 255*HashLen")
	}
}

func TestKeyScheduleRFC8448(t *testing.T) {
	zero := make([]byte, 32)
	shared := v8448(t, "shared_secret")

	// early_secret = HKDF-Extract(0, 0)
	early := hkdfExtract(zero, zero)
	if !bytes.Equal(early[:], v8448(t, "early_secret")) {
		t.Fatalf("early_secret mismatch")
	}

	// derived = Derive-Secret(early, "derived", "")
	emptyHash := sha256Sum(nil)
	derived := deriveSecret(early, "derived", emptyHash)
	if !bytes.Equal(derived[:], v8448(t, "derived_early_secret")) {
		t.Fatalf("derived_early_secret mismatch")
	}

	// handshake_secret = HKDF-Extract(derived, shared)
	hsSecret := hkdfExtract(derived[:], shared)
	if !bytes.Equal(hsSecret[:], v8448(t, "handshake_secret")) {
		t.Fatalf("handshake_secret mismatch")
	}

	// The transcript through ClientHello||ServerHello, recomputed from the
	// published flight (never taken on trust).
	th := transcriptHash(rfc8448Flight[:2])
	cHS := deriveSecret(hsSecret, "c hs traffic", th)
	sHS := deriveSecret(hsSecret, "s hs traffic", th)
	if !bytes.Equal(cHS[:], v8448(t, "client_hs_traffic_secret")) {
		t.Fatalf("client_hs_traffic_secret mismatch")
	}
	if !bytes.Equal(sHS[:], v8448(t, "server_hs_traffic_secret")) {
		t.Fatalf("server_hs_traffic_secret mismatch")
	}

	sKey := trafficKey(sHS)
	if !bytes.Equal(sKey[:], v8448(t, "server_hs_write_key")) {
		t.Fatalf("server_hs_write_key mismatch")
	}
	sIV := trafficIv(sHS)
	if !bytes.Equal(sIV[:], v8448(t, "server_hs_write_iv")) {
		t.Fatalf("server_hs_write_iv mismatch")
	}
	cKey := trafficKey(cHS)
	if !bytes.Equal(cKey[:], v8448(t, "client_hs_write_key")) {
		t.Fatalf("client_hs_write_key mismatch")
	}
	cIV := trafficIv(cHS)
	if !bytes.Equal(cIV[:], v8448(t, "client_hs_write_iv")) {
		t.Fatalf("client_hs_write_iv mismatch")
	}

	sfKey := finishedKey(sHS)
	if !bytes.Equal(sfKey[:], v8448(t, "server_finished_key")) {
		t.Fatalf("server_finished_key mismatch")
	}
	cfKey := finishedKey(cHS)
	if !bytes.Equal(cfKey[:], v8448(t, "client_finished_key")) {
		t.Fatalf("client_finished_key mismatch")
	}

	// Application secrets need the transcript through the server's Finished.
	thAP := transcriptHash(rfc8448Flight[:6])
	derivedM := deriveSecret(hsSecret, "derived", emptyHash)
	master := hkdfExtract(derivedM[:], zero)
	cAP := deriveSecret(master, "c ap traffic", thAP)
	if !bytes.Equal(cAP[:], v8448(t, "client_ap_traffic_secret")) {
		t.Fatalf("client_ap_traffic_secret mismatch")
	}
	sAP := deriveSecret(master, "s ap traffic", thAP)
	if !bytes.Equal(sAP[:], v8448(t, "server_ap_traffic_secret")) {
		t.Fatalf("server_ap_traffic_secret mismatch")
	}
	cAppKey := trafficKey(cAP)
	if !bytes.Equal(cAppKey[:], v8448(t, "client_app_write_key")) {
		t.Fatalf("client_app_write_key mismatch")
	}
}

// transcriptHash hashes the named flight messages in order (the vectors are
// generated from vetted hex, so decoding cannot fail).
func transcriptHash(flight []struct{ name, bytes string }) [32]byte {
	h := sha256Init()
	for _, m := range flight {
		h.write(hexDecode(m.bytes))
	}
	return h.sum()
}
