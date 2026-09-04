# live-httpd.spec -- HTTPD.BIN (exec'd) passively opens port 8080:
# the monitor shows tcp=listen while the server lives.
# Mirrors tools/verify-live-httpd.sh (claim 0750). Legacy's -E needles
# (HTTPD\.BIN, tcp=listen) are fixed-string-equivalent.

vgate_name live-httpd "HTTPD.BIN passive open on 8080, tcp=listen on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/tcp.zig kernel/src/syscall.zig kernel/src/monitor.zig user/src/lib/ui.zig user/src/httpd.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
exec HTTPD.BIN
echo httpd-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
net
echo httpd-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'httpd: listening on port 8080' --script-expect 'httpd-ok' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'httpd: starting'
vgate_assert 01 serial-contains 'httpd: listening on port 8080'
vgate_assert 01 serial-contains 'echo httpd-launched'
vgate_assert 01 serial-contains 'HTTPD.BIN'
vgate_assert 01 serial-contains 'tcp=listen'
vgate_assert 01 serial-contains 'echo httpd-ok'
