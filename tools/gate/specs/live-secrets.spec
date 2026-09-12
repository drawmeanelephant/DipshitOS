# live-secrets.spec -- M50 TS5 class-B gate (issue #1139, ADR 0024 D8/D10).
#
# The secret store live, on one share with a host-seeded `SECRETS.TXT`
# (`#v1`, one `key<TAB>uid<TAB>value` line): (1) the EL1h monitor's
# `secrets` command lists the key NAME only; (2) the EL0 shell's `secrets`
# builtin (through `sys_secret_get`, slot 70) lists the SAME key NAME;
# (3) `SECRETS.TXT` is denied at BOTH seams — the monitor's `vf cat` and
# the EL0 file ABI `cat < SECRETS.TXT` — because TS5 registers it
# secret-class BY CONSTRUCTION, not only via a hand-seeded OWNERS.TXT;
# (4) the known secret VALUE never appears anywhere in the serial capture
# while its NAME does. Boot default unchanged: no secret is read at boot on
# a default share.

vgate_name live-secrets "#1139 TS5: secrets store — names listable, SECRETS.TXT denied at both seams, value never logged"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The EL1h monitor session: prove the direct-consumer seam first (`vf cat`
# is denied even for uid_system + CAP_FS_ANY), then the monitor `secrets`
# name listing, then hand the console to SH.BIN for the EL0 file-ABI +
# sys_secret_get session.
vgate_file script.txt <<'EOF'
secrets
vf cat SECRETS.TXT
exec SH.BIN
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
# Host-seeded secret store. A 64-char value (a 32-byte Ed25519 seed in hex)
# is the canonical max; a short marker value proves serial-absence loudly.
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "netkey\t1000\tTS5-TOPSECRET-VALUE\n"
)
# The EL0 shell session; CR (0x0d) submits on this seam.
open(os.path.join(run, "edit.bin"), "wb").write(
    b"secrets\r"
    b"cat < SECRETS.TXT\r"
    b"echo ts5-done\r"
)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.bin' \
    --script2-after 'sh: attached' \
    --script-expect 'ts5-done' \
    --script-expect-tail 16 \
    --timeout 90

# The key NAME is listable at BOTH seams: the EL1h monitor `secrets` command
# and the EL0 shell `secrets` builtin (via sys_secret_get).
vgate_assert 01 serial-contains 'secrets:'
vgate_assert 01 serial-count '  netkey' 2
# Direct-consumer seam: the monitor's own secret read is denied (the class
# holds by construction, so even with no OWNERS.TXT entry the file is denied).
vgate_assert 01 serial-contains 'vf cat: SECRETS.TXT: permission denied'
# EL0 file ABI: the only in-guest reader is sys_secret_get; cat is denied.
vgate_assert 01 serial-contains 'sh: cannot open SECRETS.TXT: EACCES'
vgate_assert 01 serial-contains 'ts5-done'
# Never-logged contract: the known VALUE never reaches the serial transcript,
# while its NAME (above) does. Names travel; values do not.
vgate_assert 01 serial-absent 'TS5-TOPSECRET-VALUE'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# The host share still holds the seeded value untouched (no sys_secret_set
# exists; the guest never writes SECRETS.TXT).
vgate_assert 01 python <<'PY'
import os, sys
p = os.path.join(os.environ["VG_SHARE"], "SECRETS.TXT")
try:
    body = open(p, errors="replace").read()
except OSError:
    sys.exit("FAIL: SECRETS.TXT missing from the host share")
if "netkey\t1000\tTS5-TOPSECRET-VALUE" not in body:
    sys.exit("FAIL: seeded SECRETS.TXT entry was modified: " + repr(body))
print("secrets host inspection ok")
PY