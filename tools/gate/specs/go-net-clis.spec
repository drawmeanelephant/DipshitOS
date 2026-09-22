# go-net-clis.spec -- M71n (issue #1573) class-B gate: the Go net CLIs are
# reached BY TYPING THEM AT A GOSH PROMPT on a live network.
#
# The card's daily bar is "type a net verb in GOSH and get a Go program". Two
# things could be true while that bar is still unmet: the binaries exist but
# nothing names them (deliverable 1's `help` half, pinned by the host tests in
# user/go/sh -- TestHelpNamesTheNetCLIs), or GOSH cannot actually launch them
# over a real device. This spec is the second half, and it is the only place
# that runs: the exec goes through GOSH's OWN parser and RunExternal seam, so
# the marker below is GOSH's child's output, not the monitor's.
#
#   boot 01   GOSH (serial console) types `exec GOPING.ELF -c 3 10.0.0.2`
#             against the runner's ICMP responder  -> 3 round trips, exit 0
#   boot 02   GOSH types `exec GOFETCH.ELF https://10.0.0.2:24533/`
#             against the pinned TLS 1.3 fixture relayed to the guest
#             ->  `gofetch: handshake ok` / `gofetch: body complete`
#
# WHY THE CONSOLE SHELL AND NOT THE WINDOW: a windowed GOSH would need
# GOTABWM.ELF staged and a third live Go runtime (seat + shell + CLI), and
# go-sh.spec records that a THIRD SEQUENTIAL exec from one EL0 parent dies in
# the Go runtime's own schedinit. `GOSH.ELF serial` (ADR 0020 selector 1) is
# the same engine, the same parser and the same RunExternal, with only the
# monitor (Zig) as its parent -- so the two-Go-runtime envelope every
# go-* spec already proves holds here.
#
# WHY A NEW SPEC rather than a run in live-sh.spec: live-sh.spec owns the
# shell CORE (builtins, history, help) on a share with no network at all, and
# the two boots below need `--net` plus a device responder. The split keeps
# that spec's share pristine.
#
# WHAT PROVES THE EXEC CAME FROM GOSH, precisely, because the obvious reading
# is stronger than the wire supports: `exec: loaded <NAME>` is the MONITOR's
# line (kernel/src/monitor.zig cmd_exec) and an EL0 `sys_exec` does not print
# it. So the proof is a negative plus a positive:
#   * `exec: loaded GOPING.ELF` is ABSENT -- the monitor never ran it; and
#   * GOSH's own `gosh: line exec GOPING.ELF ...` submit record is present,
#     which only its line editor and parser produce; and
#   * the child's OWN output follows, ordered after that record.
# The monitor-side script contains neither the typed line nor the child's
# markers, so a boot in which GOSH never spawned the CLI cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF
#   bash tools/go/build-goping.sh    ->  .build/go/GOPING.ELF
#   bash tools/go/build-web.sh fetch GOFETCH -> .build/go/GOFETCH.ELF

vgate_name go-net-clis "issue #1573 M71n: GOSH execs GOPING.ELF (ICMP) and GOFETCH.ELF (TLS) on a live VZ net"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Boot 01, phase 1: the monitor brings the interface up BEFORE the shell takes
# the console (GOSH's serial front-end owns the input once it attaches, so
# these two lines cannot be typed after it).
vgate_file net.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

# Boot 01, phase 2: hand the console to the shell.
vgate_file sh.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, how in (("GOSH.ELF", "build-gosh.sh"),
                  ("GOPING.ELF", "build-goping.sh"),
                  ("GOFETCH.ELF", "build-web.sh fetch GOFETCH")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s (%d bytes)" % (name, os.path.getsize(src)))
# The typed lines are raw console bytes (CR submits a line in GOSH's editor),
# so they are written here rather than as a heredoc.
with open(os.path.join(rd, "typed-ping.bin"), "wb") as f:
    f.write(b"exec GOPING.ELF -c 3 10.0.0.2\r")
with open(os.path.join(rd, "typed-fetch.bin"), "wb") as f:
    f.write(b"exec GOFETCH.ELF https://10.0.0.2:24533/\r")
PY

# The TLS 1.3 responder the Go shelf's own fixtures use (leaf.example.com,
# AutoClaw test CA), reached through the runner's :relay -- the recipe
# live-web.spec boot 12 pins.
vgate_setup_python <<'PY'
import os, subprocess, sys
rd = os.environ["RUN_DIR"]
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)
cmd = [
    sys.executable,
    os.path.join("user", "src", "lib", "tls", "vectors", "tlsresponder.py"),
    "--host", "127.0.0.1", "--port", "24533",
    "--cert", chain, "--key", os.path.join(cfx, "leaf-ec.key"),
    "--body", "go-net-clis-ok\n", "--accept", "2", "--timeout", "3600",
]
log = open(os.path.join(rd, "tlsresponder.log"), "wb")
proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("go-net-clis: tlsresponder pid=%d on 127.0.0.1:24533" % proc.pid)
PY

# --- boot 01: GOSH execs GOPING.ELF over the ICMP responder ----------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --net '$RUN_DIR/cap-01.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-ping.bin' --script3-after 'gosh: attached' \
    --script-expect 'ping statistics' --timeout 180

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
# The monitor did NOT run it (`exec: loaded` is the monitor's own line, see
# the header): this run cannot be satisfied by a monitor-script exec.
vgate_assert 01 serial-absent 'exec: loaded GOPING.ELF'
# ...and the child's own output. GOPING prints the header before the first
# send, so a header alone would prove only that it started; the statistics
# footer is printed after the last poll and cannot exist unless the ICMP
# round trip completed.
vgate_assert 01 serial-contains 'PING 10.0.0.2 (10.0.0.2): 56 data bytes'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=1'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=2'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=3'
vgate_assert 01 serial-contains '--- 10.0.0.2 ping statistics ---'
vgate_assert 01 serial-contains '3 packets transmitted, 3 packets received, 0% packet loss'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'fatal error: runtime:'
# The typed line is what the shell received: `exec ` is GOSH's own verb, and
# the printed markers are GOSH's `gosh: line ` submit record of it.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Anchored at line start, tolerant of a kernel log line spliced onto the
# tail (go-sh.spec observed that interleave); the reject case is a monitor
# line that merely CONTAINS the text, which starts with `gosh: line exec`
# only if the shell actually submitted it.
m = re.search(r"(?m)^gosh: line exec GOPING\.ELF -c 3 10\.0\.0\.2", ser)
if not m:
    sys.exit("FAIL: GOSH never recorded the typed `exec GOPING.ELF ...` line")
header = ser.find("PING 10.0.0.2 (10.0.0.2): 56 data bytes")
stats = ser.find("ping statistics")
if header < 0 or stats < 0 or not m.start() < header < stats:
    sys.exit("FAIL: order want typed(%d) < header(%d) < statistics(%d)"
             % (m.start(), header, stats))
print("go-net-clis 01 ok: GOSH exec'd GOPING.ELF, 3 replies, statistics, ordered")
PY

# --- boot 02: GOSH execs GOFETCH.ELF against the TLS fixture ---------------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --net '$RUN_DIR/cap-02.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24533:relay --net-tcp-respond-relay 127.0.0.1:24533 \
    --script '$RUN_DIR/net.txt' \
    --script2 '$RUN_DIR/sh.txt' --script2-after 'net arp: ' \
    --script3 '$RUN_DIR/typed-fetch.bin' --script3-after 'gosh: attached' \
    --script-expect 'gofetch: ready' --timeout 240

vgate_assert 02 serial-contains 'gosh: ready'
vgate_assert 02 serial-contains 'gosh: attached'
# See run 01: the monitor's own load line is ABSENT, so the spawn was GOSH's.
vgate_assert 02 serial-absent 'exec: loaded GOFETCH.ELF'
vgate_assert 02 serial-contains 'gofetch: url https://10.0.0.2:24533/'
vgate_assert 02 serial-contains 'gofetch: handshake ok'
vgate_assert 02 serial-contains 'go-net-clis-ok'
vgate_assert 02 serial-contains 'gofetch: body complete'
vgate_assert 02 serial-absent 'gofetch: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'fatal error: runtime:'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if not re.search(r"(?m)^gosh: line exec GOFETCH\.ELF https://10\.0\.0\.2:24533/", ser):
    sys.exit("FAIL: GOSH never recorded the typed `exec GOFETCH.ELF ...` line")
if "gofetch: dial 10.0.0.2 24533" not in ser:
    sys.exit("FAIL: GOFETCH did not dial the relayed fixture")
if "gofetch: fail-closed" in ser:
    sys.exit("FAIL: the fetch failed closed; the fixture body was not read")
print("go-net-clis 02 ok: GOSH exec'd GOFETCH.ELF, TLS handshake + body")
PY
