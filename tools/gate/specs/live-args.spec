# live-args.spec -- exec arguments reach EL0: the same USER.BIN exec'd
# four times with distinct argv prints its own marker per invocation,
# all four run concurrently to completion with distinct tasks/stacks.
# Mirrors tools/verify-live-args.sh (claim 4636, card 3e).

vgate_name live-args "exec argv to EL0: same USER.BIN, distinct args, all four complete"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
ls
exec USER.BIN alpha
exec USER.BIN beta
exec USER.BIN gamma
exec USER.BIN delta
procs
echo rx-args-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 3
vgate_assert 01 serial-exact 'rx-args-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
# Legacy -Fc counts (substring lines): loaded/exited families exactly 4,
# each argv marker exactly 1 (substring, NOT whole-line: a marker can
# land on the shell's trailing prompt line).
need = {
    "exec: loaded USER.BIN size=": 4,
    "user: arg=alpha": 1, "user: arg=beta": 1,
    "user: arg=gamma": 1, "user: arg=delta": 1,
    "user: hello from the ESP": 4, "user: awake": 4,
    "tasks user-exec exited status=43": 4,
    "procs USER.BIN exited status=43": 4,
    "tasks user-exec reaped": 4,
}
bad = [(n, sum(1 for l in lines if n in l), w) for n, w in need.items()]
bad = [(n, c, w) for n, c, w in bad if c != w]
if bad:
    sys.exit("FAIL: args counts off: %s" % bad)
print("args counts ok")
PY
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
rows = [l for l in lines if re.search(r"procs: id=[0-9]+ name=USER.BIN state=running", l)]
if len(rows) != 4:
    sys.exit("FAIL: running USER.BIN rows=%d, want 4" % len(rows))
tasks, stacks = [], []
for l in rows:
    mt = re.search(r".*task=([0-9]+).*", l)
    ms = re.search(r".*stack=0x([0-9a-f]{16}).*", l)
    if not mt or not ms:
        sys.exit("FAIL: row missing task=/stack=: %r" % l)
    tasks.append(mt.group(1))
    stacks.append(ms.group(1))
if len(set(tasks)) != 4:
    sys.exit("FAIL: executor task ids not distinct: %s" % tasks)
if len(set(stacks)) != 4:
    sys.exit("FAIL: stack VAs not distinct: %s" % stacks)
fs = next((i for i, l in enumerate(lines) if "user: sleeping 2 ticks" in l), None)
la = next((i for i in range(len(lines) - 1, -1, -1) if "user: awake" in lines[i]), None)
if fs is None or la is None or not (fs < la):
    sys.exit("FAIL: sleep/wake window absent fs=%s la=%s" % (fs, la))
if not any("tasks worker advances=" in l for l in lines[fs + 1:la]):
    sys.exit("FAIL: no worker advance between first sleep and last wake")
print("args custom ok")
PY
