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

# Run 03 (M70g G2, #1459 — ADR 0022 D2 amendment): the secret comes from a
# FILE (`--console-tcp-secret-file`, so it is never on argv) and the two
# pre-auth negatives are pinned in one boot:
#   silent  connects at once (before the guest prompt — the bridge listens
#           from process start) and never answers the challenge: the
#           connected-but-mute shape of a half-open peer. It must be dropped
#           with `console-tcp: auth timeout` after the 10 s deadline;
#   real    waits for the prompt, is told `busy` while silent holds the seat,
#           retries, then authenticates with the file's secret and drives
#           the monitor.
# The python assert pins that the secret text never reaches runner stdout/
# stderr. Only the LAST client's exit code is enforced by the harness, so the
# silent client writes its own capture and is pinned by asserts.
vgate_file secret.txt <<'EOF'
f1l3-s3cret
EOF

vgate_run 03 -- --console-tcp '127.0.0.1:24681' --console-tcp-secret-file '$RUN_DIR/secret.txt' --timeout 45
vgate_client 03 -- --addr '127.0.0.1:24681' --connect-timeout 30 \
    --expect 'auth timeout' --timeout 20 --out '$RUN_DIR/client-03-silent.out'
vgate_client 03 -- --addr '127.0.0.1:24681' --after 'virelai>' --retry-busy --connect-timeout 30 \
    --hmac-secret f1l3-s3cret --send-file '$RUN_DIR/accept.txt' --expect 'remote-console-ok' --timeout 20

vgate_assert 01 client-contains 'auth failed'
vgate_assert 01 output-contains 'console-tcp: auth failed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 client-contains 'remote-console-ok'
vgate_assert 02 serial-contains 'remote-console-ok'
vgate_assert 02 output-contains 'console-tcp: client authenticated'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 03 output-contains 'secret from file'
vgate_assert 03 output-contains 'console-tcp: auth timeout'
vgate_assert 03 output-contains 'console-tcp: client authenticated'
vgate_assert 03 client-contains 'remote-console-ok'
vgate_assert 03 serial-contains 'remote-console-ok'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os
run = os.environ['RUN_DIR']
silent = open(os.path.join(run, 'client-03-silent.out'), 'rb').read()
assert b'VIRELAIOS-AUTH/1 hmac-sha256' in silent, silent
assert b'console-tcp: auth timeout' in silent, silent
out = open(os.path.join(run, 'run-%s.out' % os.environ['VG_TAG']), 'rb').read()
assert b'f1l3-s3cret' not in out, 'the bridge secret leaked into runner output'
PY
