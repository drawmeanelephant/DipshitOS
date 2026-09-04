# live-sleep.spec -- blocking syscalls: USER.BIN yields, sleeps 2
# ticks (woken by the timer, worker advances mid-sleep), wakes, and
# exits; the sys_sleep slot row is frozen in the dispatch table.
# Mirrors tools/verify-live-sleep.sh (claim 0635).

vgate_name live-sleep "yield/sleep/wakeup blocking syscalls on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec USER.BIN
syscalls
echo rx-sleep-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 2
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-exact 'rx-sleep-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -Fc = 1 (substring lines): load + EL0 markers + sleep pair +
# the task exit (substring, not whole-line).
need = ["exec: loaded USER.BIN size=", "user: hello from the ESP",
        "user: exec ok", "user: sleeping 2 ticks", "user: awake",
        "tasks user-exec exited status=43"]
bad = [(n, sum(1 for l in lines if n in l)) for n in need]
bad = [(n, c) for n, c in bad if c != 1]
if bad:
    sys.exit("FAIL: sleep markers not exactly-once: %s" % bad)
# Legacy -Fc >= 1: the sys_sleep slot row is frozen in the table.
if sum(1 for l in lines if "4 sys_sleep" in l) < 1:
    sys.exit("FAIL: no sys_sleep slot row")
# Legacy -Ec shape: the syscall report (counts drift -- rows below).
if not re.search(r"syscalls: slots=[0-9]+ implemented=[0-9]+", ser):
    sys.exit("FAIL: no syscalls report")
# A worker advance strictly between sleep and wake (other tasks run
# while this one is blocked).
fs = next((i for i, l in enumerate(lines) if "user: sleeping 2 ticks" in l), None)
la = next((i for i, l in enumerate(lines) if "user: awake" in l), None)
if fs is None or la is None or not (fs < la):
    sys.exit("FAIL: sleep/wake window absent fs=%s la=%s" % (fs, la))
if not any("tasks worker advances=" in l for l in lines[fs + 1:la]):
    sys.exit("FAIL: no worker advance between sleep and wake")
print("sleep markers + slot + interleave ok")
PY
