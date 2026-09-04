# live-userspace.spec -- first EL0 task: SVC round-trip plus timer
# preemption back to the EL1h shell. Mirrors
# tools/verify-live-userspace.sh (claim 8215). The user-row shape is ERE
# in the original, so it rides the python escape hatch (see SPEC.md).

vgate_name live-userspace "EL0 SVC round-trip + timer preemption"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: tasks / echo rx-el0-ok"

vgate_file script.txt <<'EOF'
tasks
echo rx-el0-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tasks: enabled=1'
vgate_assert 01 serial-contains 'userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0'
vgate_assert 01 serial-contains 'rx-el0-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
need = [
    r"user-el0 +saves=[0-9]+ resumes=[0-9]+ advances=0",
    r"tasks worker advances=[1-9][0-9]*",
]
missing = [p for p in need if not re.search(p, ser)]
if missing:
    sys.exit("FAIL: userspace row patterns absent: %s" % missing)
print("userspace rows ok: user-el0 row + worker advance hold")
PY
