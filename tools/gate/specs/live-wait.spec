# live-wait.spec -- sys_wait (slot 8): COUNTER.BIN blocks on
# STATUS43.BIN's pid while the target still runs, then observes
# status=43 from EL0 the moment the ring resumes it.
# Mirrors tools/verify-live-wait.sh (claim 9946, card 4c).

vgate_name live-wait "sys_wait observes a peer exit status on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
ls
exec STATUS43.BIN
exec COUNTER.BIN 0 1
procs
echo rx-wait-phase1
EOF

vgate_file script2.txt <<'EOF'
tasks
procs
echo rx-wait-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'ipc: waiting pid=1' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'STATUS43.BIN' 2
vgate_assert 01 serial-count 'exec: loaded STATUS43.BIN size=' 1
vgate_assert 01 serial-count 'exec: loaded COUNTER.BIN size=' 1
vgate_assert 01 serial-count 'status43: alive' 1
vgate_assert 01 serial-count 'status43: exiting' 1
vgate_assert 01 serial-count 'ipc: waiting pid=1' 1
vgate_assert 01 serial-count 'tasks user-exec exited status=43' 1
vgate_assert 01 serial-count 'procs STATUS43.BIN exited status=43' 1
vgate_assert 01 serial-count 'tasks user-exec reaped' 1
vgate_assert 01 serial-count 'ipc: saw pid=1 status=43' 1
vgate_assert 01 serial-exact 'rx-wait-phase1' 1
vgate_assert 01 serial-exact 'rx-wait-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -cE >= 2: the phase-2 snapshot shows the waiter AND the
# sleeper as blocked user-exec rows (the boot payload is user-el0).
if sum(1 for l in lines if re.search(r"user-exec.*state=blocked", l)) < 2:
    sys.exit("FAIL: fewer than 2 blocked user-exec rows")
# Ordering: waiting marker < target still running < observed status.
wl = next((i for i, l in enumerate(lines) if "ipc: waiting pid=1" in l), None)
sl = next((i for i, l in enumerate(lines) if "ipc: saw pid=1 status=43" in l), None)
rls = [i for i, l in enumerate(lines)
       if re.search(r"procs: id=[0-9]+ name=STATUS43.BIN state=running", l)]
if wl is None or sl is None or not rls:
    sys.exit("FAIL: wait/saw/running-row absent wl=%s sl=%s rows=%d" % (wl, sl, len(rls)))
if not (wl < rls[-1] < sl):
    sys.exit("FAIL: order off wait=%d running=%d saw=%d" % (wl, rls[-1], sl))
print("wait blocked + order ok")
PY
