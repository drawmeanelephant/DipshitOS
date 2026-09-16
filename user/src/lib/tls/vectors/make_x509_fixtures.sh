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
#
# Pinning rule
# ------------
# openssl genkey / ecparam -genkey produces a FRESH RANDOM CA on every run.
# FETCHS.BIN vendors vectors/fx/root.pem (as DER) at build time via
# vendored_roots.zig. Regenerating into the committed fx/ directory without
# also re-emitting vendored_roots.zig desyncs the guest trust store; the
# live TLS path then fails closed with ChainValidationFailed. That is the
# trap this script used to spring silently.
#
# The committed fx/ set is the live identity. Do not overwrite it. Default
# invocation refuses to write there. `--check` generates into a temp dir and
# compares the new root DER against the vendored anchor (this FAILS, which
# is the point). `--check <dir>` compares that dir's root against the pin
# without generating (the committed fx/ set PASSES).
#
# Usage:
#   bash make_x509_fixtures.sh --check              # fresh regen vs pin → fail
#   bash make_x509_fixtures.sh --check DIR          # DIR/root vs pin, no regen
#   bash make_x509_fixtures.sh OUT_DIR              # generate into OUT_DIR
#   bash make_x509_fixtures.sh --write-committed    # overwrite fx/; loud; don't
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMITTED_FX="$HERE/fx"
VENDORED="$HERE/../vendored_roots.zig"
EMIT="$HERE/emit_vendored_roots.py"

CHECK=0
WRITE_COMMITTED=0
OUT=""
CHECK_TMP=""

usage() {
    cat <<'EOF'
Usage:
  bash make_x509_fixtures.sh --check              # fresh regen vs pin → fail
  bash make_x509_fixtures.sh --check DIR          # DIR/root vs pin, no regen
  bash make_x509_fixtures.sh OUT_DIR              # generate into OUT_DIR
  bash make_x509_fixtures.sh --write-committed    # overwrite fx/; loud; don't
EOF
}

cleanup() {
    if [ -n "${CHECK_TMP:-}" ]; then
        rm -rf "$CHECK_TMP"
    fi
}
trap cleanup EXIT

absdir() {
    (cd "$1" && pwd)
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --write-committed) WRITE_COMMITTED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*)
            echo "make_x509_fixtures.sh: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$OUT" ]; then
                echo "make_x509_fixtures.sh: unexpected extra argument: $1" >&2
                usage >&2
                exit 2
            fi
            OUT="$1"
            shift
            ;;
    esac
done

# Convert a fixture dir's root.pem/root.der to a DER path without writing
# into that dir (the committed fx/ set must not be mutated).
root_der_of() {
    local dir="$1"
    if [ -f "$dir/root.der" ]; then
        printf '%s\n' "$dir/root.der"
        return 0
    fi
    if [ -f "$dir/root.pem" ]; then
        if [ -z "$CHECK_TMP" ]; then
            CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/x509-pin.XXXXXX")"
        fi
        openssl x509 -in "$dir/root.pem" -outform der -out "$CHECK_TMP/root.der"
        printf '%s\n' "$CHECK_TMP/root.der"
        return 0
    fi
    echo "make_x509_fixtures.sh: no root.der or root.pem in $dir" >&2
    return 1
}

check_against_vendored() {
    local der="$1"
    local version
    if [ ! -f "$VENDORED" ]; then
        echo "make_x509_fixtures.sh --check: missing vendored blob $VENDORED" >&2
        return 1
    fi
    version="$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' "$VENDORED")"
    if [ -z "$version" ]; then
        echo "make_x509_fixtures.sh --check: cannot read version from $VENDORED" >&2
        return 1
    fi
    python3 "$EMIT" --check "$version" "$VENDORED" "$der"
}

# ---- generate (OpenSSL 3.x) ----
# Runs in a subshell so it cannot cd the caller. openssl genkey is random:
# two runs never produce the same root.
generate_into() {
    local dest="$1"
    mkdir -p "$dest"
    (
        cd "$dest"
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

        # ---- leaf under ca-nc whose SAN is in the EXCLUDED subtree ----
        openssl ecparam -name prime256v1 -genkey -noout -out leaf-ncevil.key 2>/dev/null
        openssl req -new -key leaf-ncevil.key -subj "/CN=evil.example.com$SUBJ" -out leaf-ncevil.csr 2>/dev/null
        printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:evil.example.com\n' > leaf-ncevil.ext
        openssl x509 -req -in leaf-ncevil.csr -CA ca-nc.pem -CAkey ca-nc.key -CAcreateserial \
            -days $DAYS -sha256 -extfile leaf-ncevil.ext -out leaf-ncevil.pem 2>/dev/null
        der leaf-ncevil.pem

        # ---- leaf under ca-nc whose SAN is OUTSIDE the permitted subtree ----
        openssl ecparam -name prime256v1 -genkey -noout -out leaf-ncother.key 2>/dev/null
        openssl req -new -key leaf-ncother.key -subj "/CN=other.example$SUBJ" -out leaf-ncother.csr 2>/dev/null
        printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:other.com\n' > leaf-ncother.ext
        openssl x509 -req -in leaf-ncother.csr -CA ca-nc.pem -CAkey ca-nc.key -CAcreateserial \
            -days $DAYS -sha256 -extfile leaf-ncother.ext -out leaf-ncother.pem 2>/dev/null
        der leaf-ncother.pem

        # ---- leaf with NO subjectAltName extension at all (CN fallback case) ----
        openssl ecparam -name prime256v1 -genkey -noout -out leaf-cn.key 2>/dev/null
        openssl req -new -key leaf-cn.key -subj "/CN=cnonly.example.com$SUBJ" -out leaf-cn.csr 2>/dev/null
        printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' > leaf-cn.ext
        openssl x509 -req -in leaf-cn.csr -CA inter.pem -CAkey inter.key -CAcreateserial \
            -days $DAYS -sha256 -extfile leaf-cn.ext -out leaf-nosan.pem 2>/dev/null
        der leaf-nosan.pem

        echo "generated in $dest:"
        ls -1 *.der | sed 's/^/  /'
        echo "openssl: $(openssl version)"
    )
}

if [ "$CHECK" -eq 1 ]; then
    if [ -n "$OUT" ]; then
        echo "make_x509_fixtures.sh --check: comparing $(absdir "$OUT") against $VENDORED (no regen)"
        derpath="$(root_der_of "$OUT")"
        check_against_vendored "$derpath"
        exit $?
    fi
    CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/x509-pin.XXXXXX")"
    echo "make_x509_fixtures.sh --check: generating a fresh CA into $CHECK_TMP"
    echo "openssl genkey is random; this new root cannot match the vendored pin."
    generate_into "$CHECK_TMP"
    check_against_vendored "$CHECK_TMP/root.der"
    exit $?
fi

if [ "$WRITE_COMMITTED" -eq 1 ]; then
    if [ -z "$OUT" ]; then
        OUT="$COMMITTED_FX"
    fi
fi

if [ -z "$OUT" ]; then
    echo "make_x509_fixtures.sh: refusing to write the committed fx/ set." >&2
    echo "openssl genkey produces a fresh random CA every run; overwriting" >&2
    echo "$COMMITTED_FX would desync vendored_roots.zig / FETCHS.BIN." >&2
    echo "Pass an output directory, --check, or --write-committed (don't)." >&2
    usage >&2
    exit 2
fi

mkdir -p "$OUT"
if [ "$(absdir "$OUT")" = "$(absdir "$COMMITTED_FX")" ] && [ "$WRITE_COMMITTED" -eq 0 ]; then
    echo "make_x509_fixtures.sh: refusing to overwrite committed fx/ without --write-committed." >&2
    echo "A silent regen desyncs the build-time-pinned root in vendored_roots.zig." >&2
    echo "If you intend to rotate the guest trust store, re-emit vendored_roots.zig" >&2
    echo "from the new root.der in the same change as the new fx/ set." >&2
    exit 2
fi

if [ "$WRITE_COMMITTED" -eq 1 ]; then
    echo "WARNING: overwriting committed $COMMITTED_FX with a FRESH random CA." >&2
    echo "You MUST re-emit vendored_roots.zig from the new root.der in the same" >&2
    echo "change, or FETCHS.BIN will fail closed (ChainValidationFailed)." >&2
fi

generate_into "$OUT"
