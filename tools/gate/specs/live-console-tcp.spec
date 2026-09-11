# live-console-tcp.spec -- M46 RC2 pilot (issue #1069): the declarative
# during-run TCP client hook (`vgate_client`) drives the Stage 0 host console
# bridge (`--console-tcp`, PR #1070) and proves a host client can type into
# the guest console and see the reply in the serial log.
#
# Run 02 is the negative: with NO bridge listener the same hook must observe
# the connection refused (`--expect-fail`). This spec is the pilot for the
# tools/gate/SPEC.md format extension (new `vgate_client` command +
# `client-contains` assert); the mechanism is reused by
# live-remote-console.spec (M46 RC4, #1112).

vgate_name live-console-tcp "M46 RC2 pilot: during-run TCP client hook drives --console-tcp (#1069)"

vgate_file cmd.txt <<'EOF'
echo console-tcp-ok
EOF

vgate_run 01 -- --console-tcp '127.0.0.1:24680' --timeout 60
vgate_client 01 -- --addr '127.0.0.1:24680' --after 'virelai>' \
    --send-file '$RUN_DIR/cmd.txt' --expect 'console-tcp-ok' --timeout 25

# Run 02 negative: a console boot with NO bridge listener on 24698 — the
# client hook (`--expect-fail`) must observe the connection refused.
vgate_run 02 -- --console --timeout 20
vgate_client 02 -- --addr '127.0.0.1:24698' --connect-timeout 3 --expect-fail

vgate_assert 01 serial-contains 'console-tcp-ok'
vgate_assert 01 client-contains 'console-tcp-ok'
vgate_assert 01 output-contains 'console-tcp: client connected'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 client-contains 'refused as expected'
vgate_assert 02 output-contains 'mode: interactive console'
