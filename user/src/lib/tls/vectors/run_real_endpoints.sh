#!/usr/bin/env bash
# Real-endpoint interop runs for the in-tree TLS 1.3 client.
#
# Resolves each host to an IPv4, feeds the system root bundle to the driver on
# stdin, and appends a ledger line per run. Includes negatives that must fail
# closed. Every row is a real handshake against the public internet.
#
# Usage: bash run_real_endpoints.sh <driver> <ledger.jsonl>
set -uo pipefail

DRV="${1:?driver}"
LEDGER="${2:?ledger}"

BUNDLE="${TLS_ROOT_BUNDLE:-/etc/ssl/cert.pem}"
echo "=== Real endpoints: $(date -u +%Y-%m-%dT%H:%M:%SZ) (bundle $BUNDLE) ==="

run() { # label host port servername
  local label="$1" host="$2" port="$3" sni="$4"
  # dig may return a CNAME for a "A" query; take the first bare IPv4.
  local ip; ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  if [ -z "$ip" ]; then
    echo "{\"peer\":\"$label\",\"outcome\":\"dns_failed\",\"detail\":\"no A record for $host\"}" >> "$LEDGER"
    echo "  $label -> dns_failed"
    return
  fi
  cat "$BUNDLE" | "$DRV" "$label" "public-web" "$(date +%s)" "$ip" "$port" "$sni" "@stdin" >> "$LEDGER"
  echo "  $label ($host -> $ip) -> $(tail -1 "$LEDGER" | grep -o '"outcome":"[^"]*"')"
}

# Positive: real-world chains (ECDSA and RSA, with intermediates).
run "Cloudflare (ECDSA)"   cloudflare.com   443 cloudflare.com
run "GitHub (RSA+chain)"   github.com       443 github.com
run "Google"               www.google.com   443 www.google.com
run "example.com"          example.com      443 example.com
run "Apple"                www.apple.com    443 www.apple.com
run "Wikipedia"            en.wikipedia.org 443 en.wikipedia.org
run "Let's Encrypt"        letsencrypt.org  443 letsencrypt.org
run "Mozilla"              www.mozilla.org  443 www.mozilla.org

# Negative: must fail closed.
run "badssl self-signed"   self-signed.badssl.com 443 self-signed.badssl.com
run "badssl expired"       expired.badssl.com     443 expired.badssl.com
run "badssl wrong-host"    wrong.host.badssl.com  443 example.com

echo "=== ledger now $(wc -l < "$LEDGER") rows ==="
