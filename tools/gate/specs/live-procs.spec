# live-procs.spec -- the PROCESS abstraction above the task pool: the
# boot payload's process keeps exited status=7 past reap, exec USER.BIN
# is a running process with its stack, and its process exit report
# survives the executor's reap.
# Mirrors tools/verify-live-procs.sh (claim 3848, card 3).

vgate_name live-procs "process abstraction: image + address space + lifecycle + exit status"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
ls
exec USER.BIN
procs
echo rx-procs-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 2
vgate_assert 01 serial-exact 'tasks user-exec exited status=43' 1
vgate_assert 01 serial-exact 'procs USER.BIN exited status=43' 1
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-exact 'rx-procs-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy running-row / boot-exited are ORs: pass when EITHER side holds.
if not (sum(1 for l in lines if "procs: id=" in l) >= 1 or "name=USER.BIN state=running" in ser):
    sys.exit("FAIL: no running USER.BIN process row")
if "name=user-el0 state=exited" not in ser and "exit=7" not in ser:
    sys.exit("FAIL: boot payload process not exited with status 7")
# Legacy -Fc = 1: exactly one line containing the needle.
need = ["exec: loaded USER.BIN size=", "user: hello from the ESP", "user: exec ok"]
bad = [(n, sum(1 for l in lines if n in l)) for n in need]
bad = [(n, c) for n, c in bad if c != 1]
if bad:
    sys.exit("FAIL: procs markers not exactly-once: %s" % bad)
print("procs rows + markers ok")
PY
