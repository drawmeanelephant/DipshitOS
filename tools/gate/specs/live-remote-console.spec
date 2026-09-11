# live-remote-console.spec -- M46 RC4 class-B gate (issue #1112, ADR 0022).
#
# The Stage 0 host console bridge with the v1 bridge secret: the runner's
# `--console-tcp 127.0.0.1:24681:s3cret` serves the guest serial console on a
# TCP socket and requires the client's first line to match. Driven by the M46
# RC2 during-run client hook (`vgate_client`, issue #1069): run 01 sends the
# WRONG secret and must be rejected; run 02 sends the RIGHT secret, drives the
# guest monitor (`echo remote-console-ok`), and sees the reply. Boot default is
# unchanged — the bridge exists only when the flag is given.

vgate_name live-remote-console "M46 RC4: vgate client hook + --console-tcp secret bridge — reject/accept (#1112, ADR 0022)"

vgate_file wrong.txt <<'EOF'
wrong
EOF

vgate_file accept.txt <<'EOF'
s3cret
echo remote-console-ok
EOF

vgate_run 01 -- --console-tcp '127.0.0.1:24681:s3cret' --timeout 25
vgate_client 01 -- --addr '127.0.0.1:24681' --after 'virelai>' \
    --send-file '$RUN_DIR/wrong.txt' --expect 'auth failed' --timeout 15

vgate_run 02 -- --console-tcp '127.0.0.1:24681:s3cret' --timeout 30
vgate_client 02 -- --addr '127.0.0.1:24681' --after 'virelai>' \
    --send-file '$RUN_DIR/accept.txt' --expect 'remote-console-ok' --timeout 20

vgate_assert 01 client-contains 'auth failed'
vgate_assert 01 output-contains 'console-tcp: auth failed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 client-contains 'remote-console-ok'
vgate_assert 02 serial-contains 'remote-console-ok'
vgate_assert 02 output-contains 'console-tcp: client authenticated'
vgate_assert 02 serial-absent '[EXC] parking:'
