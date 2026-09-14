#!/usr/bin/env bash
# Interop matrix runner for the in-tree TLS 1.3 client (card TLS13-C5).
#
# Starts four independent peer implementations (and two negative endpoints),
# runs the host-side driver against each, and appends one JSON line per run to
# the machine-readable ledger. Every ledger row is produced by the driver
# actually completing (or failing) a real handshake.
#
# Usage: bash run_interop.sh <driver-binary> <fixture-dir> <out-ledger.jsonl>
set -uo pipefail

DRV="${1:?driver binary}"
FX="${2:?fixture dir}"
LEDGER="${3:?ledger path}"

ROOT_HEX=$(xxd -p -c 100000 "$FX/root.der" | tr -d '\n')
# A chain PEM (leaf then intermediate) for peers that want one file.
cat "$FX/leaf-ec.pem" "$FX/inter.pem" > "$FX/chain-ec.pem"
cat "$FX/leaf-rsa.pem" "$FX/inter.pem" > "$FX/chain-rsa.pem"

mkdir -p "$(dirname "$LEDGER")"

# A genuinely self-signed leaf whose issuer is not in the trust store, for the
# untrusted-endpoint negative.
if [ ! -f "$FX/selfsigned.pem" ]; then
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$FX/selfsigned.key" -out "$FX/selfsigned.pem" \
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
    -www -naccept 1 "$@" > "$FX/../s_server-$port.log" 2>&1 &
  echo $!
}

echo "=== Interop run: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
: > "$LEDGER"

# 1. OpenSSL s_server, ECDSA P-256 leaf.
P=$(start_openssl 8453 "$FX/leaf-ec.pem" "$FX/leaf-ec.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (ECDSA)" "$(openssl version | awk '{print $2}')" 8453 leaf.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 2. OpenSSL s_server, RSA-2048 leaf under the same intermediate.
P=$(start_openssl 8454 "$FX/leaf-rsa.pem" "$FX/leaf-rsa.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (RSA)" "$(openssl version | awk '{print $2}')" 8454 rsa.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 3. GnuTLS serv, ECDSA leaf.
if command -v gnutls-serv >/dev/null; then
  gnutls-serv --port 8455 --http --x509certfile "$FX/chain-ec.pem" --x509keyfile "$FX/leaf-ec.key" \
    > "$FX/../gnutls-8455.log" 2>&1 &
  P=$!
  sleep 1; run "gnutls-serv" "$(gnutls-cli --version 2>/dev/null | head -1 | awk '{print $2}')" 8455 leaf.example.com "$ROOT_HEX"
  kill $P 2>/dev/null; wait $P 2>/dev/null
else
  echo '{"peer":"gnutls-serv","outcome":"skipped","detail":"gnutls-serv not installed"}' >> "$LEDGER"
fi

# 4. Go crypto/tls server (pre-built so the driver is not racing compilation).
if command -v go >/dev/null; then
  GOSRV="$(dirname "$0")/goserver.go"
  GOBIN="$FX/goserver"
  if [ ! -x "$GOBIN" ]; then (cd "$FX" && go build -o "$GOBIN" "$GOSRV") >/dev/null 2>&1; fi
  # Serve the *chain* (leaf + intermediate), as a real server would.
  "$GOBIN" "$FX/chain-ec.pem" "$FX/leaf-ec.key" 8456 > "$FX/../go-8456.log" 2>&1 &
  P=$!
  sleep 2; run "go crypto/tls" "$(go version | awk '{print $3}')" 8456 leaf.example.com "$ROOT_HEX"
  kill $P 2>/dev/null; wait $P 2>/dev/null
else
  echo '{"peer":"go crypto/tls","outcome":"skipped","detail":"go not installed"}' >> "$LEDGER"
fi

# 5. NEGATIVE: a self-signed certificate that does not chain to the trust store.
P=$(start_openssl 8457 "$FX/selfsigned.pem" "$FX/selfsigned.key" "$FX/selfsigned.pem")
sleep 1; run "openssl s_server (self-signed)" "$(openssl version | awk '{print $2}')" 8457 selfsigned.example.com "$ROOT_HEX"; wait $P 2>/dev/null

# 6. NEGATIVE: right chain, wrong hostname.
P=$(start_openssl 8458 "$FX/leaf-ec.pem" "$FX/leaf-ec.key" "$FX/inter.pem")
sleep 1; run "openssl s_server (wrong hostname)" "$(openssl version | awk '{print $2}')" 8458 wrong.example.com "$ROOT_HEX"; wait $P 2>/dev/null

echo "=== ledger: $LEDGER ($(wc -l < "$LEDGER") rows) ==="
