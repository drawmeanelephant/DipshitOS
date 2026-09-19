# live-trust-whoami.spec -- M50 TS1 class-B gate (issue #1135, ADR 0024 D2),
# retargeted to GOSH by M68b (#1450).
#
# The principal surface live: every EL0 process is `uid_user` (1000) with no
# caps. The EL1h monitor's `procs` row reports the SAME descriptor field the
# new `sys_principal` slot (68) hands to EL0, so the kernel seam and the
# syscall seam must agree. GOSH is asked for `whoami`/`id` over /dev/tty via
# the serial front-end. Boot default unchanged: no new syscall is on the boot
# path.

vgate_name live-trust-whoami "#1135 TS1 identity: whoami/id (sys_principal 68) agree with the monitor procs row"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
procs
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
print("staged GOSH.ELF (%d bytes) into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# Ask the shell for its principal, then a marker so the gate can stop.
seq = b"whoami\rid\recho whoami-ok\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/edit.bin' \
    --script2-after 'gosh: attached' \
    --script-expect 'whoami-ok' \
    --script-expect-tail 16 \
    --timeout 90

# Kernel seam: the monitor's procs row for the boot payload (uid_user, no caps).
vgate_assert 01 serial-contains 'procs: id=0 name=user-el0 uid=1000 caps=0'
# Syscall seam: sys_principal(68) rendered by the whoami/id builtins.
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'uid=1000 user'
vgate_assert 01 serial-contains 'uid=1000 user caps=0'
vgate_assert 01 serial-contains 'whoami-ok'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
