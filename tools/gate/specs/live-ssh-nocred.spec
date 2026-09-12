# live-ssh-nocred.spec -- M51 SSH5 (#1172, ADR 0025 D8) class-B negative:
# missing credential fails closed.
#
# The host share has a TS5 store with NO `ssh-user-ed25519` entry. The guest
# completes KEX and the host-key pin, the responder offers `publickey`, and
# the client fails closed with its distinct `MissingCredential` status and
# exit 5 — no secret to read, no session. Serial-absent '[EXC] parking:'.

vgate_name live-ssh-nocred "M51 SSH5: SSH.BIN with no ssh-user-ed25519 credential fails closed (MissingCredential, rc=5)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt user/src/*.zig user/src/lib/ssh/*.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec SSH.BIN alice@10.0.0.2:2222 VIRELAI-GATE-EXEC
echo ssh-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo ssh-nocred-done
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
os.makedirs(os.path.join(share, "SSH"), exist_ok=True)
# A valid secret store with an unrelated entry only: no ssh-user-ed25519.
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "netkey\t1000\tunrelated-value\n"
)
open(os.path.join(share, "SSH", "KNOWN_HOSTS"), "w").write(
    "#v1\n"
    "10.0.0.2\t2222\tssh-ed25519\td75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a\n"
)
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:2222:ssh \
    --script '$RUN_DIR/script-1.txt' \
    --script2 '$RUN_DIR/script-2.txt' \
    --script2-after 'ssh: fail stage=auth rc=5' \
    --script-expect 'tasks user-exec reaped' \
    --timeout 120

vgate_assert 01 serial-contains 'ssh: kex-ok'
vgate_assert 01 output-contains 'SSH-SRV: service-accept ssh-userauth'
vgate_assert 01 output-contains 'SSH-SRV: userauth none requested; offering publickey'
vgate_assert 01 serial-contains 'ssh: auth-error MissingCredential'
vgate_assert 01 serial-contains 'ssh: fail stage=auth rc=5'
vgate_assert 01 serial-absent 'ssh: auth-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
