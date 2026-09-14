//! RFC 8448 §3 "Simple 1-RTT Handshake" intermediate values — GENERATED.
//!
//! Source: https://www.rfc-editor.org/rfc/rfc8448.txt
//! sha256 of the fetched file:
//!   6564d1376d1ec744fc7a9993da15ebc1b9be361908b166091f47ef605c537fba
//! Extraction: `vectors/extract_rfc8448.py` / `vectors/emit_rfc8448_zig.py`.
//! Every block's collected byte count is checked against the octet count
//! printed in the RFC before this file is written, and the handshake
//! messages are checked to parse (type byte + 3-byte length == remaining).
//!
//! All values are hex text; tests decode with std.fmt.hexToBytes.

pub const client_private_key = "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005";
pub const client_public_key = "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c";
pub const server_private_key = "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e";
pub const server_public_key = "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f";
pub const early_secret = "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a";
pub const derived_early_secret = "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba";
pub const shared_secret = "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d";
pub const handshake_secret = "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac";
pub const client_hs_traffic_secret = "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21";
pub const server_hs_traffic_secret = "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38";
pub const derived_master_secret = "43de77e0c77713859a944db9db2590b53190a65b3ee2e4f12dd7a0bb7ce254b4";
pub const master_secret = "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919";
pub const client_ap_traffic_secret = "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5";
pub const server_ap_traffic_secret = "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643";
pub const exporter_master_secret = "fe22f881176eda18eb8f44529e6792c50c9a3f89452f68d8ae311b4309d3cf50";
pub const resumption_master_secret = "7df235f2031d2a051287d02b0241b0bfdaf86cc856231f2d5aba46c434ec196c";
pub const server_hs_write_key = "3fce516009c21727d0f2e4e86ee403bc";
pub const server_hs_write_iv = "5d313eb2671276ee13000b30";
pub const client_hs_write_key = "dbfaa693d1762c5b666af5d950258d01";
pub const client_hs_write_iv = "5bd3c71b836e0b76bb73265f";
pub const server_finished_key = "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8";
pub const server_finished_message = "140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718";
pub const client_app_write_key = "17422dda596ed5d9acd890e3c63f5051";
pub const client_app_write_iv = "5b78923dee08579033e523d9";
pub const client_app_record = "1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab3f2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3deae63aeebb21694915e4";
pub const client_app_payload = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031";
pub const client_finished_key = "b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4";
pub const client_finished_message = "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61";

pub const HandshakeMessage = struct { name: []const u8, bytes: []const u8 };

/// The server's handshake flight in wire order, as published (these are
/// the *plaintext* handshake messages, header included).
pub const server_flight = [_]HandshakeMessage{
    .{ .name = "ClientHello", .bytes = "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001" },
    .{ .name = "ServerHello", .bytes = "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304" },
    .{ .name = "EncryptedExtensions", .bytes = "080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000" },
    .{ .name = "Certificate", .bytes = "0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000" },
    .{ .name = "CertificateVerify", .bytes = "0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3" },
    .{ .name = "Finished", .bytes = "140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718" },
};
