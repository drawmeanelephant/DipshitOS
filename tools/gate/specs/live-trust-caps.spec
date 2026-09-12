# live-trust-caps.spec -- M50 TS3 class-B gate (issue #1137, ADR 0024 D5/D10).
#
# The process-privilege gate live, in two boots on one seeded share:
# (1) the EL1h monitor ADMIN-SPAWNS a uid_system probe (`exec -u0
# COUNTER.BIN`; `procs` reads uid=0 caps=3), a uid_user TOP.BIN tries to
# kill it cross-principal and gets EACCES (-7) from slot 29's gate — and
# the probe keeps running after the denial, so nothing was armed;
# (2) the boot default unchanged: a uid_user TOP.BIN kills a uid_user
# COUNTER.BIN (same-uid) exactly as before — success, status 137, markers
# stop. The admin spawn is monitor-only: EL0 has no principal argument.

vgate_name live-trust-caps "#1137 TS3: kill gate — uid_user cross-principal EACCES, uid_system probe survives, same-uid kill unchanged"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Boot 01: the uid_system probe, then the uid_user killer (TOP's 'k').
vgate_file script1.txt <<'EOF'
exec -u0 COUNTER.BIN
procs
exec TOP.BIN
EOF

# After the denied kill: a final procs row + the syscall counter, then stop.
vgate_file script2.txt <<'EOF'
procs
syscalls
echo trust-caps-denied
EOF

vgate_run 01 -- --display --input \
    --script '$RUN_DIR/script1.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'top: kill pid=1 err=-7' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'trust-caps-denied' \
    --timeout 75

# Kernel principal: the admin spawn assigned uid_system + both caps.
vgate_assert 01 serial-contains 'procs: id=1 name=COUNTER.BIN uid=0 caps=3'
# EL0 denial: the uid_user caller's cross-principal kill is EACCES (-7) at
# the syscall seam — and the syscall was actually dispatched (counted).
vgate_assert 01 serial-contains 'top: kill pid=1 err=-7'
vgate_assert 01 serial-contains '29 sys_kill calls=1'
vgate_assert 01 serial-contains 'trust-caps-denied'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

# The denial armed nothing: the uid_system probe's markers continue after
# the EACCES line, and its final procs row is still running.
vgate_assert 01 python <<'PY'
import os, sys, re
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
denied = next((i for i, l in enumerate(lines) if "top: kill pid=1 err=-7" in l), None)
if denied is None:
    sys.exit("FAIL: no cross-principal EACCES (-7) denial line")
after = sum(1 for l in lines[denied + 1:] if "counter: alive" in l)
if after < 1:
    sys.exit("FAIL: uid_system probe produced no markers after the denied kill (it was armed)")
if "uid=1000" not in ser:
    sys.exit("FAIL: no uid_user principal observed in the run")
if not re.search(r"procs: id=1 name=COUNTER\.BIN uid=0 caps=3 state=running", ser):
    sys.exit("FAIL: uid_system probe is not still running at the end")
print("trust-caps EACCES ok: probe survived with %d markers after denial" % after)
PY

# Boot 02: the boot-default control — same-uid kill still works.
vgate_file script3.txt <<'EOF'
exec COUNTER.BIN
exec TOP.BIN
EOF

vgate_file script4.txt <<'EOF'
procs
syscalls
echo trust-caps-same-uid-ok
EOF

vgate_run 02 -- --display --input \
    --script '$RUN_DIR/script3.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script4.txt' \
    --script2-after 'tasks user-exec exited status=137' \
    --input-string 'k' \
    --input-string-after 'top: ready' \
    --script-expect 'trust-caps-same-uid-ok' \
    --timeout 75

# Same-uid kill: allowed, armed, and converted to the 137 exit path.
vgate_assert 02 serial-contains 'top: ready'
vgate_assert 02 serial-exact 'top: kill pid=1' 1
vgate_assert 02 serial-contains 'tasks user-exec exited status=137'
vgate_assert 02 serial-contains '29 sys_kill calls=1'
vgate_assert 02 serial-contains 'trust-caps-same-uid-ok'
vgate_assert 02 serial-absent '[EXC] parking:'

# The killed uid_user counter stops: no markers after the success line.
vgate_assert 02 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
killed = next((i for i, l in enumerate(lines) if l.strip() == "top: kill pid=1"), None)
if killed is None:
    sys.exit("FAIL: no same-uid kill success line")
after = sum(1 for l in lines[killed + 1:] if "counter: alive" in l)
if after != 0:
    sys.exit("FAIL: killed uid_user counter ran %d times after the kill" % after)
print("trust-caps same-uid kill ok: no markers after the kill")
PY
