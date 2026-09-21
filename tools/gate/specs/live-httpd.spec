# live-httpd.spec -- GOHTTPD.ELF (exec'd) passively opens port 8080:
# the monitor shows tcp=listen while the server lives.
#
# M71l (#1571): retargeted from the Zig HTTPD.BIN onto the Go GOHTTPD.ELF.
# The probe is deliberately unchanged -- a passive open the monitor can see --
# because this is all the gate ever proved: it never completed an HTTP
# exchange, so the Go port is not asked to invent one here. GOHTTPD's request
# parsing, routing and response formatting are covered by host tests
# (`go test ./httpd`); the live seam is the listen.
#
# GOHTTPD.ELF is a host-share ELF rather than an ESP-image binary, so the setup
# hook stages it into the share before the boot.
#
# HOST PREREQUISITE (fails honestly when missing):
#   bash tools/go/build-gohttpd.sh  ->  .build/go/GOHTTPD.ELF

vgate_name live-httpd "GOHTTPD.ELF passive open on 8080, tcp=listen on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/tcp.zig kernel/src/syscall.zig kernel/src/monitor.zig user/src/lib/ui.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
exec GOHTTPD.ELF
echo httpd-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
net
echo httpd-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

src = os.path.join(".build", "go", "GOHTTPD.ELF")
if not os.path.exists(src):
    sys.exit("GOHTTPD.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gohttpd.sh")
dst = os.path.join(share, "GOHTTPD.ELF")
shutil.copy(src, dst)
print("live-httpd: staged GOHTTPD.ELF (%d bytes)" % os.path.getsize(dst))
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'httpd: listening on port 8080' --script-expect 'httpd-ok' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'httpd: starting'
vgate_assert 01 serial-contains 'httpd: listening on port 8080'
vgate_assert 01 serial-contains 'echo httpd-launched'
vgate_assert 01 serial-contains 'GOHTTPD.ELF'
vgate_assert 01 serial-contains 'tcp=listen'
vgate_assert 01 serial-contains 'echo httpd-ok'
