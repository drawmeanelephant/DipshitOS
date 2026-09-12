# live-trust-modes.spec -- M50 TS2 class-B gate (issue #1136, ADR 0024 D3/D4/D8).
#
# The ownership/mode boundary live, on one share with a host-seeded
# `OWNERS.TXT`: (1) a uid_system-owned 0600 file is EACCES for uid_user
# through the file ABI (`cat < FILE`); (2) an UNLISTED file follows the
# documented default policy (0644, owner uid_user) and reads — the empty
# table is today's behavior; (3) the owner `chmod`s it and the guest-written
# `OWNERS.TXT` is inspected ON THE HOST; (4) a secret-class `SECRETS.TXT` is
# denied at BOTH seams (the monitor's `vf cat` and the EL0 file ABI) and its
# value never appears in the transcript. Boot default unchanged: no new
# syscall is on the boot path; a clean share has no OWNERS.TXT.

vgate_name live-trust-modes "#1136 TS2: ownership/mode EACCES, owner chmod persists to OWNERS.TXT, secret class denied"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The EL1h monitor session: prove the DIRECT-CONSUMER seam first (the monitor
# is uid_system + CAP_FS_ANY, yet a secret read is denied) at BOTH the `vf
# cat` verb and the kernel `sh <script>` loader, then hand the console to
# SH.BIN for the EL0 file-ABI session.
vgate_file script.txt <<'EOF'
vf cat SECRETS.TXT
sh SECRETS.TXT
exec SH.BIN
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
# Host-seeded files + OWNERS.TXT (`#v1`; uid_system = 0).
open(os.path.join(share, "TARGET.TXT"), "w").write("ts2-owner-content\n")
open(os.path.join(share, "PLAIN.TXT"), "w").write("ts2-plain-content\n")
open(os.path.join(share, "SECRETS.TXT"), "w").write("ts2-secret-value\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\n"
    "TARGET.TXT\t600\t0\t-\n"
    "SECRETS.TXT\t600\t0\tsecret\n"
)
# The EL0 shell session; CR (0x0d) submits on this seam.
open(os.path.join(run, "edit.bin"), "wb").write(
    b"cat < TARGET.TXT\r"
    b"cat < PLAIN.TXT\r"
    b"chmod 600 PLAIN.TXT\r"
    b"cat < SECRETS.TXT\r"
    b"echo ts2-done\r"
)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.bin' \
    --script2-after 'sh: attached' \
    --script-expect 'ts2-done' \
    --script-expect-tail 16 \
    --timeout 90

# Direct-consumer seam: the monitor's own secret read is denied for every actor
# (`vf cat`), and the kernel `sh <script>` content loader is denied too.
vgate_assert 01 serial-contains 'vf cat: SECRETS.TXT: permission denied'
vgate_assert 01 serial-contains 'sh: SECRETS.TXT: permission denied'
# EL0 file ABI: owner mismatch (uid_system-owned 0600, caller uid_user).
vgate_assert 01 serial-contains 'sh: cannot open TARGET.TXT: EACCES'
# Default policy: the unlisted file reads (the empty/absent table behavior).
vgate_assert 01 serial-contains 'ts2-plain-content'
# Owner chmod succeeds and persists.
vgate_assert 01 serial-contains 'chmod: ok'
# Secret class: file-ABI read denied even though it is uid_system-owned 0600.
vgate_assert 01 serial-contains 'sh: cannot open SECRETS.TXT: EACCES'
vgate_assert 01 serial-contains 'ts2-done'
# The secret value never reaches the serial transcript.
vgate_assert 01 serial-absent 'ts2-secret-value'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# The guest-written OWNERS.TXT, inspected on the host: the chmod persisted a
# canonical entry (group triplet zero), the pre-existing system-owned entry
# survived, and the secret class was not stripped.
vgate_assert 01 python <<'PY'
import os, sys
p = os.path.join(os.environ["VG_SHARE"], "OWNERS.TXT")
try:
    body = open(p, errors="replace").read()
except OSError:
    sys.exit("FAIL: OWNERS.TXT missing from the host share")
if "PLAIN.TXT\t600\t1000\t-" not in body:
    sys.exit("FAIL: guest-written PLAIN.TXT entry missing: " + repr(body))
if "TARGET.TXT\t600\t0\t-" not in body:
    sys.exit("FAIL: pre-existing TARGET.TXT entry lost")
if "SECRETS.TXT\t600\t0\tsecret" not in body:
    sys.exit("FAIL: SECRETS.TXT secret class lost")
print("trust-modes host inspection ok")
PY
