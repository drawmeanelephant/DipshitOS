#!/usr/bin/env bash
# Consumer interop for the in-tree TLS 1.3 client (card TLS13-C10).
#
# run_interop.sh pairs the client with OpenSSL, GnuTLS and Go. This pairs it
# with Python's `ssl` — a different binding over a possibly different OpenSSL
# build — and does so along the *consumer* path: the bytes of the vendored root
# blob and the exact identity FETCHS.BIN is built to expect. That is the
# closest thing to a consumer run that does not need a guest boot, and the
# responder it starts is the artifact a class-B gate would drive.
#
# Usage: bash run_consumer_interop.sh <driver> <fixture-dir> <ledger.jsonl>
set -uo pipefail

DRV="${1:?driver binary}"
FX="${2:?fixture dir}"
LEDGER="${3:?ledger path}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${CONSUMER_PORT:-24533}"

ROOT_HEX=$(xxd -p -c 100000 "$FX/root.der" | tr -d '\n')
# The responder wants one PEM with the chain, leaf first.
cat "$FX/leaf-ec.pem" "$FX/inter.pem" > "$FX/chain-ec.pem"
mkdir -p "$(dirname "$LEDGER")"

start_responder() { # port body
  local port="$1" body="$2"
  python3 "$HERE/tlsresponder.py" --port "$port" --cert "$FX/chain-ec.pem" \
    --key "$FX/leaf-ec.key" --accept 1 --timeout 45 --body "$body" \
    > "$FX/../responder-$port.log" 2>&1 &
  echo $!
}

wait_listen() { # pid port
  local pid="$1" port="$2" i
  for i in $(seq 1 100); do
    grep -q "listening" "$FX/../responder-$port.log" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

FAILED=0
run() { # label version port sni root expect
  local label="$1" ver="$2" port="$3" sni="$4" root="$5" expect="$6"
  local now; now=$(date +%s)
  "$DRV" "$label" "$ver" "$now" 127.0.0.1 "$port" "$sni" "$root" >> "$LEDGER"
  local out; out=$(tail -1 "$LEDGER" | grep -o '"outcome":"[^"]*"' | cut -d'"' -f4)
  if [ "$out" = "$expect" ]; then
    echo "  $label -> $out (expected $expect) OK"
  else
    echo "  $label -> $out (expected $expect) MISMATCH"; FAILED=1
  fi
}

PYVER=$(python3 -c 'import ssl; print(ssl.OPENSSL_VERSION)')

echo "== positive: python TLS 1.3, fixture identity, vendored root =="
PID=$(start_responder "$PORT" "consumer-interop-ok")
if wait_listen "$PID" "$PORT"; then
  run python-tls13 "$PYVER" "$PORT" leaf.example.com "$ROOT_HEX" ok
else
  echo "  responder did not come up; see responder-$PORT.log"; FAILED=1
fi
wait "$PID" 2>/dev/null || true

echo "== negative: same peer, wrong hostname, must fail closed =="
PORT2=$((PORT + 1))
PID2=$(start_responder "$PORT2" "consumer-interop-ok")
if wait_listen "$PID2" "$PORT2"; then
  run python-tls13-wronghost "$PYVER" "$PORT2" wrong.example.com "$ROOT_HEX" handshake_failed
else
  echo "  responder did not come up; see responder-$PORT2.log"; FAILED=1
fi
wait "$PID2" 2>/dev/null || true

echo "== responder logs =="
cat "$FX/../responder-$PORT.log" "$FX/../responder-$PORT2.log" 2>/dev/null | sed 's/^/  /'
exit "$FAILED"
