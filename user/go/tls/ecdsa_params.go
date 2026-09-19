// The P-256 / P-384 curve parameters the verifier builds its curve contexts
// from (FIPS 186-4). These are PRODUCTION constants: `ecP256`/`ecP384` in
// validate.go construct their contexts from them, and the ECDSA verifier in
// ecdsa.go parses them into Montgomery form.
//
// Provenance: the same OpenSSL `ecparam -param_enc explicit -text` origin as
// user/src/lib/tls/ecdsa_vectors.zig, whose numbers these are (they were
// copied verbatim from there, never typed by hand).
//
// Why they live here and not in the generated vectors file: a _test.go
// declaration is not part of the package a plain build sees. Kept in
// vectors_sigs_test.go they compiled under `go test` — which links the test
// files into the package under test — and failed the moment anything built
// the package for the guest, which is exactly what the M67b integration does:
//
//	tls/ecdsa.go:27:24:   undefined: curveParams
//	tls/validate.go:125:  undefined: curveP256params
//	tls/validate.go:136:  undefined: curveP384params
//
// So the generator that emits the vectors file should emit the parameter block
// as this production file, and the vectors file should reference it.
package tls

type curveParams struct{ p, b, n, gx, gy string }

var curveP256params = curveParams{
	p:  "00ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
	b:  "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
	n:  "00ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
	gx: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
	gy: "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
}

var curveP384params = curveParams{
	p:  "00fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
	b:  "00b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
	n:  "00ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
	gx: "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
	gy: "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
}
