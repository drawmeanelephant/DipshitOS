# live-net-tx.spec -- virtio-net transport + TX byte-exact on the host.
# Mirrors tools/verify-live-net-tx.sh (milestone five, card N1): DID +
# feature negotiation + queues + re-arm on the serial side; the host
# capture holds the exact frames (p1: single 46B frame; p2: 46+46+1514
# ring reuse + truncation, checked by a python layout walk like the
# original). The legacy script copies captures to artifacts as
# convenience; the verdicts (serial lines + comparisons) are all here.

vgate_name live-net-tx "virtio-net TX: transport + byte-exact host capture"
vgate_note "p1: netsend 32 -> capture == 46-byte known frame"
vgate_note "p2: netsend 32/32/3000 -> 46+46+1514 layout, frames=3"

vgate_file script-1.txt <<'EOF'
net
netsend 32
echo net-tx-ok
EOF
vgate_file script-2.txt <<'EOF'
net
netsend 32
netsend 32
netsend 3000
echo net-tx-ok
EOF

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
fixture = bytes([0xff]*6) + bytes([0x02,0,0,0,0,1]) + bytes([0x08,0]) + bytes(range(32))
assert len(fixture) == 46, len(fixture)
open(rd+"/live-net-tx-fixture.bin","wb").write(fixture)
big = bytes([0xff]*6) + bytes([0x02,0,0,0,0,1]) + bytes([0x08,0]) + bytes(i & 0xff for i in range(1500))
assert len(big) == 1514, len(big)
open(rd+"/live-net-tx-fixture-big.bin","wb").write(big)
PY

vgate_run p1 -- --net '$RUN_DIR/cap-1.bin' --script '$RUN_DIR/script-1.txt' --script-expect net-tx-ok --timeout 40
vgate_run p2 -- --net '$RUN_DIR/cap-2.bin' --script '$RUN_DIR/script-2.txt' --script-expect net-tx-ok --timeout 40

vgate_assert p1 serial-contains 'net: did=0x0000000000001041 class=0x0000000000020000 dev=1'
vgate_assert p1 serial-contains 'net: mac=02:00:00:00:00:01 source=feature'
vgate_assert p1 serial-contains 'net: feat=0x0000000000000028/0x0000000000000001'
vgate_assert p1 serial-contains 'q0=rx:size=4 q1=tx:size=4'
vgate_assert p1 serial-contains 'net: status=0x000000000000000f rearm=1'
vgate_assert p1 serial-contains 'netsend: tx ok'
vgate_assert p1 serial-contains 'net-tx-ok'
vgate_assert p1 capture-equals cap-1.bin live-net-tx-fixture.bin

vgate_assert p2 serial-contains 'net: did=0x0000000000001041 class=0x0000000000020000 dev=1'
vgate_assert p2 serial-contains 'net: mac=02:00:00:00:00:01 source=feature'
vgate_assert p2 serial-contains 'net: feat=0x0000000000000028/0x0000000000000001'
vgate_assert p2 serial-contains 'q0=rx:size=4 q1=tx:size=4'
vgate_assert p2 serial-contains 'net: status=0x000000000000000f rearm=1'
vgate_assert p2 serial-contains 'netsend: tx ok'
vgate_assert p2 serial-contains 'net-tx-ok'
vgate_assert p2 serial-contains 'netsend: tx ok frames=3'
vgate_assert p2 python <<'PY'
import os, sys
rd = os.environ["RUN_DIR"]
cap = open(rd+"/cap-2.bin","rb").read()
f1 = open(rd+"/live-net-tx-fixture.bin","rb").read()
fb = open(rd+"/live-net-tx-fixture-big.bin","rb").read()
if not (len(cap) == 1606 and cap[:46] == f1 and cap[46:92] == f1 and cap[92:] == fb):
    sys.exit("FAIL: p2 capture layout not 46+46+1514 (len=%d)" % len(cap))
print("p2 capture layout ok: 46+46+1514")
PY
