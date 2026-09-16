#!/usr/bin/env bash
# Interop matrix runner for the in-tree TLS 1.3 client (card TLS13-C5).
#
# Starts four independent peer implementations (and two negative endpoints),
# runs the host-side driver against each, and appends one JSON line per run to
# the machine-readable ledger. Every ledger row is produced by the driver
# actually completing (or failing) a real handshake.
#
# Usage: bash run_interop.sh <driver-binary> <fixture-dir> <out-ledger.jsonl>
#
# Pinning rule
# ------------
# This script CONSUMES a fixture directory; it does not call
# make_x509_fixtures.sh and it does not regenerate keys. openssl genkey
# produces a fresh random CA every run — regenerating into the committed
# vectors/fx/ set desyncs vendored_roots.zig / FETCHS.BIN and the live TLS
# path fails closed.
#
# Pass the committed vectors/fx/ directory. Runtime scratch (DER conversion,
# chain concatenations that are not in git, the self-signed negative, the Go
# helper binary, peer logs) is written next to the ledger, never into $FX.
# Committed files such as chain-ec.pem are used as-is and are not rewritten.
set -uo pipefail

DRV="${1:?driver binary}"
FX="${2:?fixture dir}"
LEDGER="${3:?ledger path}"

if [ ! -d "$FX" ]; then
  echo "run_interop.sh: fixture dir does not exist: $FX" >&2
  echo "Pass the committed user/src/lib/tls/vectors/fx/ set. Do not regenerate." >&2
  exit 1
fi

mkdir -p "$(dirname "$LEDGER")"
WORK="$(cd "$(dirname "$LEDGER")" && pwd)/interop-work"
mkdir -p "$WORK"

# Derive root DER in the work dir. The committed fx/ set ships root.pem, not
# root.der; writing a .der next to the PEMs would look like an in-place regen.
if [ -f "$FX/root.der" ]; then
  ROOT_DER="$FX/root.der"
elif [ -f "$FX/root.pem" ]; then
  openssl x509 -in "$FX/root.pem" -outform der -out "$WORK/root.der" || exit 1
  ROOT_DER="$WORK/root.der"
else
  echo "run_interop.sh: $FX has neither root.der nor root.pem" >&2
  echo "This runner does not generate a CA. Use the committed fx/ set." >&2
  exit 1
fi
ROOT_HEX=$(xxd -p -c 100000 "$ROOT_DER" | tr -d '\n')

# chain-ec.pem is committed — use it. Do not `cat > $FX/chain-ec.pem`.
if [ -f "$FX/chain-ec.pem" ]; then
  CHAIN_EC="$FX/chain-ec.pem"
elif [ -f "$FX/leaf-ec.pem" ] && [ -f "$FX/inter.pem" ]; then
  echo "run_interop.sh: $FX/chain-ec.pem missing; concatenating leaf-ec+inter into $WORK (not rewriting $FX)"
  cat "$FX/leaf-ec.pem" "$FX/inter.pem" > "$WORK/chain-ec.pem"
  CHAIN_EC="$WORK/chain-ec.pem"
else
  echo "run_interop.sh: missing chain-ec.pem / leaf-ec.pem+inter.pem in $FX" >&2
  exit 1
fi

# chain-rsa.pem is not committed. Build it in the work dir, not in $FX.
if [ ! -f "$FX/leaf-rsa.pem" ] || [ ! -f "$FX/inter.pem" ]; then
  echo "run_interop.sh: missing leaf-rsa.pem or inter.pem in $FX" >&2
  exit 1
fi
cat "$FX/leaf-rsa.pem" "$FX/inter.pem" > "$WORK/chain-rsa.pem"

# A genuinely self-signed leaf whose issuer is not in the trust store, for the
# untrusted-endpoint negative. Keep it out of the committed fx/ tree.
if [ ! -f "$WORK/selfsigned.pem" ]; then
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORK/selfsigned.key" -out "$WORK/selfsigned.pem" \
    -subj "/CN=selfsigned.example.com" -days 30 \
    -addext "subjectAltName=DNS:selfsigned.example.com" 2>/dev/null
fi

run() { # label version port servername root_hex
  local label="$1" ver="$2" port="$3" sni="$4" root="$5"
  local now; now=$(date +%s)
  # shellcheck disable=SC2086
  "$DRV" "$label" "$ver" "$now" 127.0.0.1 "$port" "$sni" "$root" >> "$LEDGER"
  echo "  $label (port $port) -> $(tail -1 "$LEDGER" | grep -o '"outcome":"[^"]*"')"
}

start_openssl() { # port cert key chain extra...
  local port="$1" cert="$2" key="$3" chain="$4"; shift 4
  openssl s_server -accept "$port" -cert "$cert" -key "$key" -cert_chain "$chain" \
    -www -naccept 1 "$@" > "$WORK/s_server-$port.log" 2>&1 &
  echo $!
}

echo "=== Interop run: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "=== fixtures (read-only): $FX ==="
echo "=== work dir: $WORK ==="
: > "$LEDGER"

# 1. OpenSSL s_server, ECDSA P-256 leaf.
P=$(start_openssl 8453 "$FX/leaf-ec.pem" "$FX/leaf-ec.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (ECDSA)" "$(openssl version | awk '{print $2}')" 8453 leaf.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 2. OpenSSL s_server, RSA-2048 leaf under the same intermediate.
P=$(start_openssl 8454 "$FX/leaf-rsa.pem" "$FX/leaf-rsa.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (RSA)" "$(openssl version | awk '{print $2}')" 8454 rsa.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 3. GnuTLS serv, ECDSA leaf.
if command -v gnutls-serv >/dev/null; then
  gnutls-serv --port 8455 --http --x509certfile "$CHAIN_EC" --x509keyfile "$FX/leaf-ec.key" \
    > "$WORK/gnutls-8455.log" 2>&1 &
  P=$!
  sleep 1; run "gnutls-serv" "$(gnutls-cli --version 2>/dev/null | head -1 | awk '{print $2}')" 8455 leaf.example.com "$ROOT_HEX"
  kill $P 2>/dev/null; wait $P 2>/dev/null
else
  echo '{"peer":"gnutls-serv","outcome":"skipped","detail":"gnutls-serv not installed"}' >> "$LEDGER"
fi

# 4. Go crypto/tls server (pre-built so the driver is not racing compilation).
if command -v go >/dev/null; then
  GOSRV="$(dirname "$0")/goserver.go"
  GOBIN="$WORK/goserver"
  if [ ! -x "$GOBIN" ]; then (cd "$WORK" && go build -o "$GOBIN" "$GOSRV") >/dev/null 2>&1; fi
  # Serve the *chain* (leaf + intermediate), as a real server would.
  "$GOBIN" "$CHAIN_EC" "$FX/leaf-ec.key" 8456 > "$WORK/go-8456.log" 2>&1 &
  P=$!
  sleep 2; run "go crypto/tls" "$(go version | awk '{print $3}')" 8456 leaf.example.com "$ROOT_HEX"
  kill $P 2>/dev/null; wait $P 2>/dev/null
else
  echo '{"peer":"go crypto/tls","outcome":"skipped","detail":"go not installed"}' >> "$LEDGER"
fi

# 5. NEGATIVE: a self-signed certificate that does not chain to the trust store.
P=$(start_openssl 8457 "$WORK/selfsigned.pem" "$WORK/selfsigned.key" "$WORK/selfsigned.pem")
sleep 1; run "openssl s_server (self-signed)" "$(openssl version | awk '{print $2}')" 8457 selfsigned.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 6. NEGATIVE: right chain, wrong hostname.
P=$(start_openssl 8458 "$FX/leaf-ec.pem" "$FX/leaf-ec.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (wrong hostname)" "$(openssl version | awk '{print $2}')" 8458 wrong.example.com "$ROOT_HEX"; wait $P 2>/dev/null

echo "=== ledger: $LEDGER ($(wc -l < "$LEDGER") rows) ==="
