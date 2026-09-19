# go-net.spec -- issue #1163 (phase 2) class-B gate: GONET.ELF proves a
# GOOS=virelai program can use File and Conn without driving TCP by hand.
#
# GONET.ELF (tools/go/gonet.go) uses the fresh virelai binding
# (user/go/vsys): os.File-shaped ReadFile of a host-share file, then
# net.Conn-shaped Dial -> Write(short GET) -> Read(pinned body) over slots
# 30-33, while a SECOND goroutine keeps a serial heartbeat running. The
# Read pays for its wait through the phase-2 readiness seam (slot 76), i.e.
# the goroutine PARKS; it does not spin in the window loop.
#
#   run 01 (the peer answers): the deterministic TCP responder replies to the
#   GET with its pinned 200 OK body. The read completes and the heartbeat is
#   running on both sides of it.
#   run 02 (the peer goes dark): `:handshake` answers the SYN with a SYN-ACK
#   and then goes SILENT on data — the "peer died mid-read" edge. The Read
#   must FAIL CLOSED (the bounded read expires) while the heartbeat KEEPS
#   printing. The python assert below pins that ORDER, which is the whole
#   point: a fail-closed read must not stop the other goroutine.
#
# M67a (#1446) added three runs for the vi socket surface (user/go/vi) —
# the N5 bar: loopback + host round trip + closed-port drop. They exec a
# SEPARATE fixture, GOVINET.ELF (tools/go/govinet.go), because GONET sits
# within a few KiB of the kernel's fixed text gap and the vi import
# overflows it:
#
#   run 03 (vidns): resolve a NAME against the host DNS responder over the
#   UDP seam (slots 9/10/11), then Dial the resolved literal, Send, Recv —
#   the live DNS + TCP round trip through user/go/vi, heartbeat intact.
#   run 04 (viloop): the loopback bar — a datagram to the guest's OWN
#   address returns to its own listen ring with NO --net armed at all.
#   run 05 (viclosed): the closed-port drop — a connect to a port nobody
#   answers refuses with the kernel's 30 s connect-timeout EINVAL while the
#   heartbeat keeps printing (the order proof, for a BLOCKING Dial).
#
# The expect string is a marker the PROGRAM prints ('gonet OK'), never a shell
# echo: an echoed marker is satisfied before the Go runtime has finished
# booting, so the runner tears the VM down mid-startup and the gate fails with
# a silent guest (go-hello.spec's pattern).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   just go-gonet + just go-govinet
#     -> .build/go/GONET.ELF, .build/go/GOVINET.ELF, .build/go/GOVIDNS.ELF
#
# WEB.ELF is NOT touched by this change (a follow-up may switch it to
# net.Conn); this gate never execs it.

vgate_name go-net "issue #1163 phase 2 + M67a: GONET.ELF reads a share file, Dials an IP literal, GETs, keeps its heartbeat through a peer that goes dark; the vi surface resolves DNS, loopbacks, and drops on a closed port"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GONET.ELF
EOF

vgate_file script-vidns.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOVIDNS.ELF
EOF

vgate_file script-viloop.txt <<'EOF'
net ip 10.0.0.1
exec GOVINET.ELF viloop
EOF

vgate_file script-viclosed.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOVINET.ELF viclosed
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GONET.ELF")
if not os.path.exists(src):
    sys.exit("GONET.ELF missing (expected " + src + ") - build it first: just go-gonet")
shutil.copy(src, os.path.join(share, "GONET.ELF"))
for name in ("GOVINET.ELF", "GOVIDNS.ELF"):
    src2 = os.path.join(".build", "go", name)
    if not os.path.exists(src2):
        sys.exit(name + " missing (expected " + src2 + ") - build it first: just go-govinet")
    shutil.copy(src2, os.path.join(share, name))
share_file = os.path.join(share, "GONET.SHARE")
with open(share_file, "w") as f:
    f.write("gonet-share-hello\n")
print("staged GONET.ELF (%d bytes), GOVINET.ELF (%d bytes), GOVIDNS.ELF (%d bytes), GONET.SHARE (%d bytes)"
      % (os.path.getsize(os.path.join(share, "GONET.ELF")),
         os.path.getsize(os.path.join(share, "GOVINET.ELF")),
         os.path.getsize(os.path.join(share, "GOVIDNS.ELF")),
         os.path.getsize(share_file)))
PY

# Run 01 -- the peer answers: the full N10 responder on 8080.
vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script.txt' --script-expect 'gonet OK' --timeout 120

# Run 02 -- the peer goes dark: SYN-ACK, then silence on data.
vgate_run 02 -- --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080:handshake \
    --script '$RUN_DIR/script.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GONET.ELF'
vgate_assert 01 serial-contains 'gonet: start'
vgate_assert 01 serial-contains 'gonet: readfile n='
vgate_assert 01 serial-contains 'gonet: connected'
vgate_assert 01 serial-contains 'gonet: wrote GET n='
vgate_assert 01 serial-contains 'gonet: hb='
vgate_assert 01 serial-contains 'gonet: body total='
vgate_assert 01 serial-contains 'gonet: heartbeat survived load'
vgate_assert 01 serial-contains 'gonet OK'
vgate_assert 01 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 01 serial-absent '[EXC] parking:'
# Phase 2.1: the EL0 clock is live on target (a 0/dead clock fails here).
vgate_assert 01 serial-contains 'gonet: clock ok'
vgate_assert 01 serial-absent 'gonet: clock DEAD'
vgate_assert 01 serial-contains 'gonet: failclosed ms='

vgate_assert 02 serial-contains 'gonet: connected'
vgate_assert 02 serial-contains 'gonet: hb='
vgate_assert 02 serial-contains 'gonet: read failed closed err='
# Phase 2.1: the same clock proof on the peer-goes-dark run.
vgate_assert 02 serial-contains 'gonet: clock ok'
vgate_assert 02 serial-absent 'gonet: clock DEAD'
vgate_assert 02 serial-contains 'gonet: failclosed ms='
vgate_assert 02 serial-contains 'gonet: heartbeat survived load'
vgate_assert 02 serial-contains 'gonet OK'
vgate_assert 02 output-contains "NET-TCP: answered the guest's SYN"
# The ORDER proof: a heartbeat line must appear AFTER the fail-closed line,
# i.e. the second goroutine kept running while the read was failing.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
fail = next((i for i, l in enumerate(lines) if "gonet: read failed closed err=" in l), None)
if fail is None:
    sys.exit("FAIL: no fail-closed marker (the peer went dark but the read did not fail closed)")
after = [i for i, l in enumerate(lines) if "gonet: hb=" in l and i > fail]
if not after:
    sys.exit("FAIL: the heartbeat did NOT continue after the read failed closed")
before = [i for i, l in enumerate(lines) if "gonet: hb=" in l and i < fail]
if not before:
    sys.exit("FAIL: the heartbeat never ran before the read blocked")
print("go-net order ok: %d heartbeats before the fail-closed line, %d after"
      % (len(before), len(after)))
PY

# --- M67a (#1446): the vi socket surface, the N5 bar -----------------------

# Run 03 -- the host round trip through vi: DNS-resolve a NAME (the host
# responder answers myhost.local -> 10.0.0.2), then Dial/Send/Recv the GET.
vgate_run 03 -- --net '$RUN_DIR/cap3.bin' --net-arp-respond 10.0.0.2 \
    --net-dns-respond 10.0.0.2:53 --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-vidns.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 03 serial-contains 'govinet: vidns start'
vgate_assert 03 serial-contains 'govinet: vidns resolved myhost.local -> 10.0.0.2'
vgate_assert 03 serial-contains 'govinet: vidns connected'
vgate_assert 03 serial-contains 'govinet: vidns sent n='
vgate_assert 03 serial-contains 'govinet: vidns body total='
vgate_assert 03 serial-contains 'gonet OK'
vgate_assert 03 output-contains "NET-DNS: answered the guest's DNS query for 'myhost.local'"
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 serial-absent 'govinet: FAIL'
vgate_assert 03 serial-absent '[EXC] parking:'

# Run 04 -- the loopback bar: the vi UDP seam's own-IP datagram comes back
# to the guest's own listen ring. No --net is armed: there is no device to
# leak onto, so a pass IS the loopback proof.
vgate_run 04 -- --script '$RUN_DIR/script-viloop.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 04 serial-contains 'govinet: viloop start'
vgate_assert 04 serial-contains 'govinet: viloop bound'
vgate_assert 04 serial-contains 'govinet: viloop sent n=4'
vgate_assert 04 serial-contains 'govinet: viloop echoed n=12'
vgate_assert 04 serial-contains 'gonet OK'
vgate_assert 04 serial-absent 'govinet: viloop no echo'
vgate_assert 04 serial-absent 'govinet: FAIL'

# Run 05 -- the closed-port drop: 8081 has no responder, so the connect
# parks in the kernel for its 30 s window and then refuses (rc = -1, the
# kernel's einval on connect timeout) while the heartbeat keeps printing.
vgate_run 05 -- --net '$RUN_DIR/cap5.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-viclosed.txt' --script-expect 'gonet OK' --timeout 120

vgate_assert 05 serial-contains 'govinet: viclosed start'
vgate_assert 05 serial-contains 'govinet: viclosed dialing 10.0.0.2:8081'
vgate_assert 05 serial-contains 'govinet: viclosed refused rc=-1'
vgate_assert 05 serial-contains 'govinet: heartbeat survived load'
vgate_assert 05 serial-contains 'gonet OK'
vgate_assert 05 serial-absent 'govinet: FAIL'
vgate_assert 05 serial-absent '[EXC] parking:'
# The ORDER proof for a BLOCKING Dial: the heartbeat ran before the dial
# started, and — the point — it kept running across the 30 s refused dial.
vgate_assert 05 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
dial = next((i for i, l in enumerate(lines) if "govinet: viclosed dialing" in l), None)
ref  = next((i for i, l in enumerate(lines) if "govinet: viclosed refused rc=" in l), None)
if dial is None or ref is None:
    sys.exit("FAIL: missing the dialing/refused markers")
before = [i for i, l in enumerate(lines) if "govinet: hb=" in l and i < dial]
during = [i for i, l in enumerate(lines) if "govinet: hb=" in l and dial < i < ref]
after  = [i for i, l in enumerate(lines) if "govinet: hb=" in l and i > ref]
if not before:
    sys.exit("FAIL: the heartbeat never ran before the dial")
if not during:
    sys.exit("FAIL: the heartbeat did NOT run during the 30 s refused dial — a blocking Dial wedged the process")
if not after:
    sys.exit("FAIL: the heartbeat did NOT continue after the refusal")
print("go-net viclosed order ok: %d beats before, %d during, %d after the refused dial"
      % (len(before), len(during), len(after)))
PY
