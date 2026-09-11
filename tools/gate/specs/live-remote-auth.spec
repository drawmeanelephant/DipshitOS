# live-remote-auth.spec -- M46 RC3 class-B gate (issue #1111, ADR 0022 D3).
#
# The authenticated guest net front-end: `SH.BIN net 2323 s3cret` hosts the
# terminal's net front-end with a first-line shared secret. A client that
# sends the WRONG secret is rejected (`auth failed`, session ended, terminal
# detached, no byte reached the shell); a client that sends the RIGHT secret
# authenticates and its next line drives the shell. The host initiates via
# the runner's --net-tcp-connect seam (VZ NAT; no guest loopback). Plaintext,
# trusted-network only — the transport asserts auth, not confidentiality.

vgate_name live-remote-auth "M46 RC3: authenticated net front-end — reject wrong secret, accept right (#1111, ADR 0022)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
exec SH.BIN net 2323 s3cret
EOF

vgate_file wrong.txt <<'EOF'
wrong
EOF

vgate_file right.txt <<'EOF'
s3cret
help
EOF

vgate_run 01 -- --net '$RUN_DIR/cap1.bin' \
    --script '$RUN_DIR/script.txt' \
    --net-tcp-connect '10.0.0.1:2323:$RUN_DIR/wrong.txt' \
    --net-tcp-connect-after 'sh: remote auth=secret' \
    --net-tcp-connect-close-after 'auth failed' \
    --script-expect 'tty net: auth failed' \
    --timeout 120

vgate_run 02 -- --net '$RUN_DIR/cap2.bin' \
    --script '$RUN_DIR/script.txt' \
    --net-tcp-connect '10.0.0.1:2323:$RUN_DIR/right.txt' \
    --net-tcp-connect-after 'sh: remote auth=secret' \
    --net-tcp-connect-close-after 'builtins:' \
    --script-expect 'tty net: detached' \
    --timeout 40

vgate_assert 01 serial-contains 'sh: remote auth=secret'
vgate_assert 01 serial-contains 'tty net: auth failed'
vgate_assert 01 output-contains 'auth failed'
vgate_assert 01 output-contains 'NET-TCP-CONNECT: handshake complete'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 serial-contains 'sh: remote auth=secret'
vgate_assert 02 output-contains 'builtins:'
vgate_assert 02 serial-contains 'tty net: detached'
vgate_assert 02 serial-absent '[EXC] parking:'
