//! ECDSA vectors — GENERATED, do not hand-edit.
//!
//! Curve constants come from `openssl ecparam -param_enc explicit -text`;
//! signatures from `openssl dgst -sign`, each asserted to verify (and the
//! mutated-signature case asserted not to) before this file was written.

pub const Curves = struct {
    p: []const u8,
    b: []const u8,
    n: []const u8,
    gx: []const u8,
    gy: []const u8,
};

pub const p256 = Curves{
    .p = "00ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
    .b = "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
    .n = "00ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
    .gx = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
    .gy = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
};
pub const p384 = Curves{
    .p = "00fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
    .b = "00b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
    .n = "00ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
    .gx = "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
    .gy = "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f",
};

pub const SigCase = struct {
    label: []const u8,
    curve: []const u8,
    hash: []const u8,
    msg: []const u8,
    pubx: []const u8,
    puby: []const u8,
    r: []const u8,
    s: []const u8,
    sig_hex: []const u8,
};

pub const sigs = [_]SigCase{
    .{
        .label = "p256-sha256-a",
        .curve = "prime256v1",
        .hash = "sha256",
        .msg = "ECDSA test vector: prime256v1 over sha256",
        .pubx = "619250024ea0e7ff3bccea17000d7c996b817f45db648755888fe6299e7e152f",
        .puby = "e38ee2fb6eb5e9c129f0697a57228f1db658cdfc97e5670417ece5936ccb5d1b",
        .r = "f748d3b48aca72321398b8bd54069ca19644d95a81e26e5c5f0d17ef02df97dc",
        .s = "37220b93d41e0c4adc606030805a7f29453b3a3074aac2d9c2c06a6bbfb29c54",
        .sig_hex = "3045022100f748d3b48aca72321398b8bd54069ca19644d95a81e26e5c5f0d17ef02df97dc022037220b93d41e0c4adc606030805a7f29453b3a3074aac2d9c2c06a6bbfb29c54",
    },
    .{
        .label = "p256-sha256-b",
        .curve = "prime256v1",
        .hash = "sha256",
        .msg = "ECDSA test vector: prime256v1 over sha256",
        .pubx = "b8c6b97fde6e9f0ea9bf1bc8b43689be797e6a360f597e4b300715b00dc72b41",
        .puby = "6ccb7b741e4734a168293274b473685df9cec4616665cd9eac26e6a2cb392f60",
        .r = "d37ccf35e4e02f9b0e85fdaee9e26834caf7df75d157aa3dea110421f3e65e53",
        .s = "a51c600efda0ccba42c783e5e726cb2c429f967c78cfcd17fbc17917e2685fd3",
        .sig_hex = "3046022100d37ccf35e4e02f9b0e85fdaee9e26834caf7df75d157aa3dea110421f3e65e53022100a51c600efda0ccba42c783e5e726cb2c429f967c78cfcd17fbc17917e2685fd3",
    },
    .{
        .label = "p384-sha384-a",
        .curve = "secp384r1",
        .hash = "sha384",
        .msg = "ECDSA test vector: secp384r1 over sha384",
        .pubx = "544caf54866239fab74a7564f32c4c0d4fe6fcaf75d2a1c9414016314feab2029d8839c777c5cc530b5244d2f81a6638",
        .puby = "b3c5ecb2673e18ba36adce056f76f2b2d2f925a3b900f0de868d2ecd444130d0b0600dfb41d32de024e33cf370bd3ed5",
        .r = "b16f14890aeb080f6328b7582d9b8c9d019ab58837fc0693e0deff58fbbda82ddf25e0fb12462462db76ab8a45651169",
        .s = "91c8d371853fc3bfc240ab520618007eeb95496e1f6d1791027bafed1e2bed747f330efb153b38becfb0e94636c7ed78",
        .sig_hex = "3066023100b16f14890aeb080f6328b7582d9b8c9d019ab58837fc0693e0deff58fbbda82ddf25e0fb12462462db76ab8a4565116902310091c8d371853fc3bfc240ab520618007eeb95496e1f6d1791027bafed1e2bed747f330efb153b38becfb0e94636c7ed78",
    },
    .{
        .label = "p384-sha384-b",
        .curve = "secp384r1",
        .hash = "sha384",
        .msg = "ECDSA test vector: secp384r1 over sha384",
        .pubx = "6e9a04ad0a2e72d5e0ad96b5714062a5f3d838d0ad22402ca21a1d8b8b9124c919fed5058b4afb01a45fc67be1e39674",
        .puby = "fd7219b8d46201f32313eca149ad9b2076e75d952173c61ff1edad18b873f312205b78010b9b1f76f2410d5c319bf38b",
        .r = "4c28397d7bbdee3f0092a180ec98ae03ca4f853de9feec389449a8d3986e5b2a438c2fd8349321bce65f852d7347c9e5",
        .s = "e8d0b07fd29390d669c40865295d5c503479f7080f4a9e8b70fb4bb6571b4564702f8834338dd872f6d0e9ad0ad5db87",
        .sig_hex = "306502304c28397d7bbdee3f0092a180ec98ae03ca4f853de9feec389449a8d3986e5b2a438c2fd8349321bce65f852d7347c9e5023100e8d0b07fd29390d669c40865295d5c503479f7080f4a9e8b70fb4bb6571b4564702f8834338dd872f6d0e9ad0ad5db87",
    },
};
