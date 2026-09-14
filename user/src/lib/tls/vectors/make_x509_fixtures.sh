#!/usr/bin/env bash
# Generate the X.509 fixture set for the in-tree TLS 1.3 client (card TLS13-C3).
#
# Produces, under $OUT:
#   root.pem / root.key                  ECDSA P-256 root, CA:TRUE, keyCertSign
#   inter.pem / inter.key                ECDSA P-256 intermediate, CA:TRUE pathlen:0
#   leaf-ec.pem / leaf-ec.key            ECDSA leaf, SAN dNSName + a wildcard SAN
#   leaf-rsa.pem / leaf-rsa.key          RSA-2048 leaf under the same intermediate
#   leaf-ip.pem                          ECDSA leaf with an iPAddress SAN
#   leaf-nc.pem / leaf-nc.key            ECDSA leaf whose issuer carries nameConstraints
#   ca-nc.pem / ca-nc.key                ECDSA CA with critical nameConstraints
#   leaf-unknowncrit.pem                 leaf with an unknown CRITICAL extension
#   leaf-nosan.pem                       leaf with CN only, no SAN extension
#   *.der                                DER forms of each certificate above
#
# Every certificate is produced with OpenSSL 3.x; the DER is what the parser is
# tested against. Nothing here is hand-written.
set -euo pipefail

OUT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fx}"
mkdir -p "$OUT"
cd "$OUT"

SUBJ="/O=AutoClaw-TLS-Test"
DAYS=825

der() { openssl x509 -in "$1" -outform der -out "${1%.pem}.der"; }

# ---- root ----
openssl ecparam -name prime256v1 -genkey -noout -out root.key 2>/dev/null
openssl req -x509 -new -key root.key -sha256 -days 3650 \
    -subj "/CN=AutoClaw Test Root CA$SUBJ" -out root.pem \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
der root.pem

# ---- intermediate (pathlen:0) ----
openssl ecparam -name prime256v1 -genkey -noout -out inter.key 2>/dev/null
openssl req -new -key inter.key -subj "/CN=AutoClaw Test Intermediate CA$SUBJ" -out inter.csr 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > inter.ext
openssl x509 -req -in inter.csr -CA root.pem -CAkey root.key -CAcreateserial \
    -days 1825 -sha256 -extfile inter.ext -out inter.pem 2>/dev/null
der inter.pem

# ---- ECDSA leaf with dNSName SANs (one exact, one wildcard) ----
openssl ecparam -name prime256v1 -genkey -noout -out leaf-ec.key 2>/dev/null
openssl req -new -key leaf-ec.key -subj "/CN=leaf.example.com$SUBJ" -out leaf-ec.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:leaf.example.com,DNS:*.wild.example.com\n' > leaf-ec.ext
openssl x509 -req -in leaf-ec.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-ec.ext -out leaf-ec.pem 2>/dev/null
der leaf-ec.pem

# ---- RSA-2048 leaf under the same intermediate ----
openssl genrsa -out leaf-rsa.key 2048 2>/dev/null
openssl req -new -key leaf-rsa.key -subj "/CN=rsa.example.com$SUBJ" -out leaf-rsa.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:rsa.example.com\n' > leaf-rsa.ext
openssl x509 -req -in leaf-rsa.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-rsa.ext -out leaf-rsa.pem 2>/dev/null
der leaf-rsa.pem

# ---- leaf with an iPAddress SAN ----
openssl ecparam -name prime256v1 -genkey -noout -out leaf-ip.key 2>/dev/null
openssl req -new -key leaf-ip.key -subj "/CN=ip.example.com$SUBJ" -out leaf-ip.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,IP:2001:db8::1\n' > leaf-ip.ext
openssl x509 -req -in leaf-ip.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-ip.ext -out leaf-ip.pem 2>/dev/null
der leaf-ip.pem

# ---- CA carrying critical nameConstraints (permitted + excluded DNS) ----
openssl ecparam -name prime256v1 -genkey -noout -out ca-nc.key 2>/dev/null
openssl req -new -key ca-nc.key -subj "/CN=AutoClaw Name-Constrained CA$SUBJ" -out ca-nc.csr 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\nnameConstraints=critical,permitted;DNS:.example.com,excluded;DNS:.evil.example.com\nsubjectKeyIdentifier=hash\n' > ca-nc.ext
openssl x509 -req -in ca-nc.csr -CA root.pem -CAkey root.key -CAcreateserial \
    -days 1825 -sha256 -extfile ca-nc.ext -out ca-nc.pem 2>/dev/null
der ca-nc.pem

# ---- leaf issued by that CA ----
openssl ecparam -name prime256v1 -genkey -noout -out leaf-nc.key 2>/dev/null
openssl req -new -key leaf-nc.key -subj "/CN=nc.example.com$SUBJ" -out leaf-nc.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:nc.example.com\n' > leaf-nc.ext
openssl x509 -req -in leaf-nc.csr -CA ca-nc.pem -CAkey ca-nc.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-nc.ext -out leaf-nc.pem 2>/dev/null
der leaf-nc.pem

# ---- leaf with an unknown CRITICAL extension (private-arc OID) ----
openssl ecparam -name prime256v1 -genkey -noout -out leaf-unk.key 2>/dev/null
openssl req -new -key leaf-unk.key -subj "/CN=unknown.example.com$SUBJ" -out leaf-unk.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:unknown.example.com\n1.3.6.1.4.1.55555.1=critical,DER:04:03:01:02:03\n' > leaf-unk.ext
openssl x509 -req -in leaf-unk.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-unk.ext -out leaf-unknowncrit.pem 2>/dev/null
der leaf-unknowncrit.pem

# ---- leaf with NO subjectAltName extension at all (CN fallback case) ----
openssl ecparam -name prime256v1 -genkey -noout -out leaf-cn.key 2>/dev/null
openssl req -new -key leaf-cn.key -subj "/CN=cnonly.example.com$SUBJ" -out leaf-cn.csr 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' > leaf-cn.ext
openssl x509 -req -in leaf-cn.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
    -days $DAYS -sha256 -extfile leaf-cn.ext -out leaf-nosan.pem 2>/dev/null
der leaf-nosan.pem

echo "generated in $OUT:"
ls -1 *.der | sed 's/^/  /'
echo "openssl: $(openssl version)"
