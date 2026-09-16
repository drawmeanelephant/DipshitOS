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
# The expect string is a marker the PROGRAM prints ('gonet OK'), never a shell
# echo: an echoed marker is satisfied before the Go runtime has finished
# booting, so the runner tears the VM down mid-startup and the gate fails with
# a silent guest (go-hello.spec's pattern).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   just go-gonet   (or `just go-toolchain`) -> .build/go/GONET.ELF
#
# WEB.ELF is NOT touched by this change (a follow-up may switch it to
# net.Conn); this gate never execs it.

vgate_name go-net "issue #1163 phase 2: GONET.ELF reads a share file, Dials an IP literal, GETs, and keeps its heartbeat through a peer that goes dark"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GONET.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GONET.ELF")
if not os.path.exists(src):
    sys.exit("GONET.ELF missing (expected " + src + ") - build it first: just go-gonet")
shutil.copy(src, os.path.join(share, "GONET.ELF"))
share_file = os.path.join(share, "GONET.SHARE")
with open(share_file, "w") as f:
    f.write("gonet-share-hello\n")
print("staged GONET.ELF (%d bytes) and GONET.SHARE (%d bytes)"
      % (os.path.getsize(os.path.join(share, "GONET.ELF")), os.path.getsize(share_file)))
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

vgate_assert 02 serial-contains 'gonet: connected'
vgate_assert 02 serial-contains 'gonet: hb='
vgate_assert 02 serial-contains 'gonet: read failed closed err='
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
