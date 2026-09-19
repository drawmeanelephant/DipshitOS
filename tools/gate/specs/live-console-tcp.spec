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

# Run 03 (M70g G2, #1459 — ADR 0022 D2 amendment): the hardened bridge's
# negatives in ONE boot, four clients in declaration order:
#   a     types a PARTIAL line (no newline) and holds the seat 4 s;
#   busy  connects while `a` holds it and must be told `console-tcp: busy`
#         (no backlog limbo);
#   b     waits for the guest's `^C` echo — the bridge cancelled a's partial
#         line when a left — then runs a command whose output must be a clean
#         line (a zombie partial would glue `zombie-lineecho ...` together);
#   big   sends a 3000-byte line with no newline: the bridge refuses it
#         (`line too long`), drops the client, and cancels the guest line.
# Harness note: only the LAST client's exit code is enforced and the default
# capture is shared, so the earlier clients write their own `--out` files and
# are pinned by the serial/output/python asserts below.
vgate_setup_python <<'PY'
import os
run = os.environ['RUN_DIR']
with open(os.path.join(run, 'partial.txt'), 'wb') as f:
    f.write(b'echo zombie-line')  # deliberately NO newline
with open(os.path.join(run, 'big.txt'), 'wb') as f:
    f.write(b'A' * 3000 + b'\n')
PY
vgate_file clean.txt <<'EOF'
echo console-tcp-clean
EOF

vgate_run 03 -- --console-tcp '127.0.0.1:24682' --timeout 60
vgate_client 03 -- --addr '127.0.0.1:24682' --after 'virelai>' \
    --send-file '$RUN_DIR/partial.txt' --hold 4 --timeout 2 --out '$RUN_DIR/client-03-a.out'
vgate_client 03 -- --addr '127.0.0.1:24682' --after 'echo zombie-line' \
    --expect 'console-tcp: busy' --timeout 5 --out '$RUN_DIR/client-03-busy.out'
vgate_client 03 -- --addr '127.0.0.1:24682' --after '^C' --retry-busy \
    --send-file '$RUN_DIR/clean.txt' --expect 'console-tcp-clean' --timeout 25 --out '$RUN_DIR/client-03-b.out'
vgate_client 03 -- --addr '127.0.0.1:24682' --after 'console-tcp-clean' --retry-busy \
    --send-file '$RUN_DIR/big.txt' --expect 'line too long' --timeout 25

vgate_assert 01 serial-contains 'console-tcp-ok'
vgate_assert 01 client-contains 'console-tcp-ok'
vgate_assert 01 output-contains 'console-tcp: client connected'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 02 client-contains 'refused as expected'
vgate_assert 02 output-contains 'mode: interactive console'
vgate_assert 03 output-contains 'console-tcp: second client refused (busy'
vgate_assert 03 output-contains 'client disconnected mid-line (partial line cancelled with ^C)'
vgate_assert 03 output-contains 'console-tcp: line too long'
vgate_assert 03 serial-contains 'echo zombie-line'
vgate_assert 03 serial-contains '^C'
vgate_assert 03 serial-absent 'zombie-lineecho'
vgate_assert 03 serial-contains 'console-tcp-clean'
vgate_assert 03 client-contains 'line too long'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os
run = os.environ['RUN_DIR']
# Order in the serial log: the echoed partial line, then the bridge's ^C
# cancel, then the clean command's output. (Not contiguous: the guest's
# self-test / worker-report lines interleave, observed 2026-09-18.)
ser = open(os.environ['VG_SER'], 'rb').read()
i_partial = ser.find(b'echo zombie-line')
i_cancel = ser.find(b'^C', i_partial)
i_clean = ser.find(b'\nconsole-tcp-clean', i_cancel)
assert 0 <= i_partial < i_cancel < i_clean, (i_partial, i_cancel, i_clean)
busy = open(os.path.join(run, 'client-03-busy.out'), 'rb').read()
assert b'console-tcp: busy' in busy, busy
clean = open(os.path.join(run, 'client-03-b.out'), 'rb').read()
assert b'console-tcp-clean' in clean, clean
assert b'console-tcp: busy' not in clean, 'client b should have retried past busy, not captured it'
PY
