# live-remote-console.spec -- M46 RC4 class-B gate (issue #1112, ADR 0022).
#
# The Stage 0 host console bridge with the M50 TS4 HMAC challenge-response
# (ADR 0024 D7): `--console-tcp 127.0.0.1:24681:s3cret` serves the guest
# serial console and answers the client only when it presents
# hex(HMAC-SHA256(secret, "VIRELAIOS-AUTH/1 hmac-sha256" || 0x00 ||
# challenge)). Driven by the during-run client hook (`vgate_client`,
# issue #1069) with `--hmac-secret`: run 01 answers with the WRONG secret
# and must be rejected; run 02 answers correctly and drives the guest
# monitor (`echo remote-console-ok`). Boot default is unchanged — the
# bridge exists only when the flag is given.

vgate_name live-remote-console "M46 RC4: vgate client hook + --console-tcp secret bridge — reject/accept (#1112, ADR 0022)"

vgate_file wrong.txt <<'EOF'
wrong
EOF

vgate_file accept.txt <<'EOF'
echo remote-console-ok
EOF

vgate_run 01 -- --console-tcp '127.0.0.1:24681:s3cret' --timeout 25
vgate_client 01 -- --addr '127.0.0.1:24681' --after 'virelai>' \
    --hmac-secret wrong --send-file '$RUN_DIR/wrong.txt' --expect 'auth failed' --timeout 15

vgate_run 02 -- --console-tcp '127.0.0.1:24681:s3cret' --timeout 30
vgate_client 02 -- --addr '127.0.0.1:24681' --after 'virelai>' \
    --hmac-secret s3cret --send-file '$RUN_DIR/accept.txt' --expect 'remote-console-ok' --timeout 20

vgate_assert 01 client-contains 'auth failed'
vgate_assert 01 output-contains 'console-tcp: auth failed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 client-contains 'remote-console-ok'
vgate_assert 02 serial-contains 'remote-console-ok'
vgate_assert 02 output-contains 'console-tcp: client authenticated'
vgate_assert 02 serial-absent '[EXC] parking:'
