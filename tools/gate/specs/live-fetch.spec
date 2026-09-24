# live-fetch.spec -- GOFETCH.ELF (exec'd) performs the cleartext HTTP/1.0
# fetch over the host TCP responder: headers before body, 200 OK, the host
# body on the wire, exit 42.
# M78b (#1683): the Zig FETCH.BIN this gate used to exec is retired. The
# fetch rows moved onto GOFETCH.ELF's explicit http:// mode (user/go/fetch
# legacy.go): same `fetch:` markers, same header-before-body order, same
# exit 42. The https:// mode of GOFETCH is untouched and stays pinned by
# go-fetch-https / live-web.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-web.sh fetch GOFETCH -> .build/go/GOFETCH.ELF

vgate_name live-fetch "GOFETCH.ELF cleartext HTTP/1.0 fetch from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFETCH.ELF")
if not os.path.exists(src):
    sys.exit("GOFETCH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh fetch GOFETCH")
shutil.copy(src, os.path.join(share, "GOFETCH.ELF"))
print("staged GOFETCH.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOFETCH.ELF")))
PY

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOFETCH.ELF http://10.0.0.2/
echo fetch-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo fetch-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'fetch: done' --script-expect 'tasks user-exec reaped' --timeout 90

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'fetch: starting'
vgate_assert 01 serial-contains 'fetch: connected'
vgate_assert 01 serial-contains 'fetch: request sent'
vgate_assert 01 serial-contains 'HTTP/1.0 200 OK'
vgate_assert 01 serial-contains 'Hello from VirelaiOS Host!'
vgate_assert 01 serial-contains 'fetch: done'
vgate_assert 01 serial-contains 'fetch: headers'
vgate_assert 01 serial-contains '--- response headers ---'
vgate_assert 01 serial-contains '--- response body ---'
vgate_assert 01 serial-contains 'echo fetch-ok'
vgate_assert 01 output-contains "NET-TCP: answered the guest's SYN"
vgate_assert 01 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 01 output-contains 'net-tcp-respond: ENABLED'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# The exit-42 reap row now names GOFETCH.ELF.
if not re.search(r"GOFETCH\.ELF\s+exit=0x000000000000002a|GOFETCH\.ELF.*state=exited.*42|GOFETCH\.ELF.*exit=0x000000000000002a", ser):
    sys.exit("FAIL: no GOFETCH.ELF exit-42 row")
# Legacy byte-offset order: the body section follows the headers.
hi = ser.find("--- response headers ---")
bi = ser.find("--- response body ---")
if hi < 0 or bi < 0 or not (bi > hi):
    sys.exit("FAIL: body section not after headers")
print("fetch exit + order ok")
PY
