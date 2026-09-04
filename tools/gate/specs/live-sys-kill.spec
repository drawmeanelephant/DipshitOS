# live-sys-kill.spec -- claim 7604 (slot 29 sys_kill): EL0 process termination.
# TOP.BIN terminates COUNTER.BIN via 'k' key; verifies exit status 137,
# no counter execution after kill, and sys_kill calls=1.

vgate_name live-sys-kill "claim 7604: EL0 process termination on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
exec COUNTER.BIN
exec TOP.BIN
EOF

vgate_file script2.txt <<'EOF'
procs
syscalls
echo done-sys-kill
EOF

vgate_run 01 -- --display --input --script '$RUN_DIR/script1.txt' --script-after 'tasks user-el0 exited status=7' --input-string 'k' --input-string-after 'top: ready' --script2 '$RUN_DIR/script2.txt' --script2-after 'tasks user-exec exited status=137' --script-expect 'done-sys-kill' --timeout 75

vgate_assert 01 serial-contains 'top: ready'
vgate_assert 01 serial-contains 'tasks user-exec exited status=137'
vgate_assert 01 serial-contains '29 sys_kill calls=1'
vgate_assert 01 serial-contains 'done-sys-kill'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os, sys, re
content = open(os.environ['VG_SER']).read()
lines = content.splitlines()
kill_idx = None
counter_before = 0
counter_after = 0
for idx, line in enumerate(lines):
    if "top: kill pid=1" in line and kill_idx is None:
        kill_idx = idx
    if "counter: alive" in line:
        if kill_idx is None:
            counter_before += 1
        else:
            counter_after += 1

if kill_idx is None:
    sys.exit("top: kill pid=1 marker not found")
if counter_before < 1:
    sys.exit("no counter: alive markers before kill")
if counter_after > 0:
    sys.exit(f"counter executed {counter_after} times after kill")
if not re.search(r"procs: id=1 name=COUNTER\.BIN state=exited .*exit=137", content):
    sys.exit("procs line for killed COUNTER.BIN missing or invalid")
if not re.search(r"procs: id=2 name=TOP\.BIN state=running", content):
    sys.exit("procs line for TOP.BIN missing or invalid")
PY
