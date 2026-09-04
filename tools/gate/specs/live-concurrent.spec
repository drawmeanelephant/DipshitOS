# live-concurrent.spec -- two USER.BIN programs live at once: both
# load, both show running with distinct tasks/stacks, the boot
# payload stays exited, both run the EL0 flow twice each with a
# worker advance mid-flight, both exit/reap exactly twice.
# Mirrors tools/verify-live-concurrent.sh (claim 0826). No
# --script-expect (the full window must elapse for both programs).

vgate_name live-concurrent "two concurrent user address spaces on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec USER.BIN
exec USER.BIN
procs
echo rx-concurrent-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 2
vgate_assert 01 serial-exact 'rx-concurrent-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -Fc counts (substring lines): both loads, every EL0 marker
# twice, both exits/reaps exactly twice (bounded FIFOs).
need = {"exec: loaded USER.BIN size=": 2, "user: hello from the ESP": 2,
        "user: exec ok": 2, "user: sleeping 2 ticks": 2, "user: awake": 2,
        "tasks user-exec exited status=43": 2,
        "procs USER.BIN exited status=43": 2, "tasks user-exec reaped": 2}
bad = [(n, sum(1 for l in lines if n in l), w) for n, w in need.items()]
bad = [(n, c, w) for n, c, w in bad if c != w]
if bad:
    sys.exit("FAIL: concurrent counts off: %s" % bad)
# The procs snapshot: exactly TWO running USER.BIN rows, distinct
# executor tasks + distinct stack VAs.
rows = [l for l in lines if re.search(r"procs: id=[0-9]+ name=USER.BIN state=running", l)]
if len(rows) != 2:
    sys.exit("FAIL: running USER.BIN rows=%d, want 2" % len(rows))
tasks, stacks = [], []
for l in rows:
    mt = re.search(r".*task=([0-9]+).*", l)
    ms = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
    if not mt or not ms:
        sys.exit("FAIL: row missing task=/stack=: %r" % l)
    tasks.append(mt.group(1))
    stacks.append(ms.group(1))
if len(set(tasks)) != 2:
    sys.exit("FAIL: executor task ids not distinct: %s" % tasks)
if len(set(stacks)) != 2:
    sys.exit("FAIL: stack VAs not distinct: %s" % stacks)
# The boot payload's process is still exited (not yet reaped).
if "name=user-el0 state=exited" not in ser:
    sys.exit("FAIL: boot payload process not exited")
# Interleave: a worker advance strictly between the FIRST sleep and
# the LAST wake (sleeps/awakes interleave on serial by construction).
fs = next((i for i, l in enumerate(lines) if "user: sleeping 2 ticks" in l), None)
la = next((i for i in range(len(lines) - 1, -1, -1) if "user: awake" in lines[i]), None)
if fs is None or la is None or not (fs < la):
    sys.exit("FAIL: sleep/wake window absent fs=%s la=%s" % (fs, la))
if not any("tasks worker advances=" in l for l in lines[fs + 1:la]):
    sys.exit("FAIL: no worker advance between first sleep and last wake")
print("concurrent counts + rows + interleave ok")
PY
