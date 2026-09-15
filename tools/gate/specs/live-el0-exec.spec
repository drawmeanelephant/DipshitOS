# live-el0-exec.spec -- EL0 sys_exec returns to the caller (issue #1333).
# EL0EXEC.BIN execs a missing name (ENOENT, caller untouched), then
# USER.BIN with argv alpha, uses the stack after spawn, waits, and both
# complete. A kstack overflow on create_as used to kill the caller.

vgate_name live-el0-exec "EL0 sys_exec: caller survives spawn + ENOENT"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
ls
exec EL0EXEC.BIN
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo rx-el0-exec-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'el0-exec: child done' --script-expect 'rx-el0-exec-ok' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-exact 'rx-el0-exec-ok' 1
vgate_assert 01 serial-contains '28 sys_exec calls=2'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'virfaulthandler'
vgate_assert 01 serial-absent 'unexpected signal'
vgate_assert 01 serial-absent 'el0-exec: exec failed'
vgate_assert 01 serial-absent 'el0-exec: enoent unexpected'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
need = {
    "el0-exec: enoent ok": 1,
    "el0-exec: parent survived": 1,
    "el0-exec: child done": 1,
    "user: arg=alpha": 1,
    "user: hello from the ESP": 1,
    "user: exec ok": 1,
    "user: awake": 1,
    "tasks user-exec exited status=43": 1,
    "tasks user-exec exited status=0": 1,
}
bad = [(n, sum(1 for l in lines if n in l), w) for n, w in need.items()]
bad = [(n, c, w) for n, c, w in bad if c != w]
if bad:
    sys.exit("FAIL: el0-exec markers off: %s" % bad)
print("el0-exec markers ok")
PY
