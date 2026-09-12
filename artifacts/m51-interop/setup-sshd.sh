#!/usr/bin/env bash
# setup-sshd.sh -- M51 interop evidence: stand up a REAL OpenSSH sshd for
# the guest SSH.BIN client (goal #1066, ADR 0025 D8, claim #1209).
#
# Writes, under artifacts/m51-interop/:
#   sshd/hostkey(.pub)     generated ssh-ed25519 host key (if absent)
#   sshd/hosttest(.pub)    a host-side sanity key (if absent)
#   sshd/authorized_keys   RFC 8032 TEST 2 client pubkey + hosttest pubkey
#   sshd/sshd_config       Port 2222, publickey only, DEBUG3, strictmodes off
#   share/SECRETS.TXT      ssh-user-ed25519 <uid> <64-hex TEST 2 seed>
#   share/SSH/KNOWN_HOSTS  <gateway-ip> <port> ssh-ed25519 <64-hex host pin>
#   share/*                zig-out/bin/* + image/APPS.TXT (gate share shape)
#   sshd-hostpin.txt       denormalized copy of the pin (for the docs)
#
# Usage: bash artifacts/m51-interop/setup-sshd.sh [gateway-ip] [port]
# Nothing here is a CI gate (ADR 0025 D8): it is a documented manual check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

GW_IP="${1:-192.168.64.1}"
PORT="${2:-2222}"
DIR="artifacts/m51-interop"
SSHD="$DIR/sshd"
SHARE="$DIR/share"
mkdir -p "$SSHD" "$SHARE/SSH"

# --- host key ---------------------------------------------------------------
if [ ! -f "$SSHD/hostkey" ]; then
    ssh-keygen -t ed25519 -f "$SSHD/hostkey" -N '' -C 'virelai-m51-interop-hostkey' </dev/null >/dev/null
fi
# A host-side sanity key: proves sshd works from the host before the guest
# run (the guest itself authenticates with the pinned TEST 2 key).
if [ ! -f "$SSHD/hosttest" ]; then
    ssh-keygen -t ed25519 -f "$SSHD/hosttest" -N '' -C 'virelai-m51-interop-hosttest' </dev/null >/dev/null
fi

# --- authorized_keys: the RFC 8032 TEST 2 client key + the host sanity key --
# TEST 2 (RFC 8032 7.1): seed 4ccd08... , public 3d4017... . The OpenSSH
# wire line is built from the hex pubkey so the pin and the auth file share
# one source of truth.
python3 - "$SSHD" "$ROOT" <<'PY'
import base64, struct, sys
sshd, root = sys.argv[1], sys.argv[2]
pub2 = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
name = b"ssh-ed25519"
key = bytes.fromhex(pub2)
blob = struct.pack(">I", len(name)) + name + struct.pack(">I", len(key)) + key
line = "ssh-ed25519 " + base64.b64encode(blob).decode() + " virelai-rfc8032-test2\n"
hosttest = open(root + "/" + sshd + "/hosttest.pub").read()
with open(root + "/" + sshd + "/authorized_keys", "w") as f:
    f.write(line)
    f.write(hosttest)
PY

cat > "$SSHD/sshd_config" <<EOF
Port $PORT
ListenAddress 0.0.0.0
HostKey $ROOT/$SSHD/hostkey
AuthorizedKeysFile $ROOT/$SSHD/authorized_keys
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
StrictModes no
PidFile $ROOT/$SSHD/sshd.pid
LogLevel DEBUG3
PrintMotd no
AcceptEnv LANG LC_*
EOF

/usr/sbin/sshd -t -f "$SSHD/sshd_config"

# --- host key pin (64 hex = the raw 32-byte ed25519 public key) -------------
PIN="$(python3 - "$SSHD/hostkey.pub" <<'PY'
import base64, sys
parts = open(sys.argv[1]).read().split()
blob = base64.b64decode(parts[1])
# ssh wire: uint32 len("ssh-ed25519"), name, uint32 len(32), key
n = int.from_bytes(blob[0:4], "big")
off = 4 + n
klen = int.from_bytes(blob[off:off+4], "big")
key = blob[off+4:off+4+klen]
assert klen == 32, klen
print(key.hex())
PY
)"
echo "$GW_IP	$PORT	ssh-ed25519	$PIN" > "$DIR/sshd-hostpin.txt"

# --- guest share ------------------------------------------------------------
cp -R zig-out/bin/. "$SHARE/" 2>/dev/null || true
[ -f image/apps.txt ] && cp image/apps.txt "$SHARE/APPS.TXT"
printf '#v1\nssh-user-ed25519\t1000\t4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb\n' > "$SHARE/SECRETS.TXT"
{
    printf '#v1\n'
    printf '%s\t%s\tssh-ed25519\t%s\n' "$GW_IP" "$PORT" "$PIN"
} > "$SHARE/SSH/KNOWN_HOSTS"

echo "sshd config: $SSHD/sshd_config"
echo "host-key pin: $GW_IP $PORT ssh-ed25519 $PIN"
echo "share: $SHARE ($(find "$SHARE" -maxdepth 1 -type f | wc -l | tr -d ' ') files)"
