# live-lifecycle.spec -- user task lifecycle on VZ hardware: EL0 exit to
# zombie, idle-task reap, runtime spawn-demo scheduling, explicit task
# states + pool/zombie counts, shell surviving every switch.
# Mirrors tools/verify-live-lifecycle.sh (claim 6729).

vgate_name live-lifecycle "user task spawn/exit/reap lifecycle with idle task on VZ"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script.txt <<'EOF'
spawn
tasks
echo rx-lifecycle-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'tasks user-el0 reaped' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tasks user-el0 exited status=7'
vgate_assert 01 serial-contains 'tasks user-el0 reaped'
vgate_assert 01 serial-contains 'rx-lifecycle-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
pats = [
    r"spawn: spawn-demo id=[0-9]+",
    r"tasks spawn-demo advances=[1-9][0-9]*",
    r"saves=[0-9]+ resumes=[0-9]+ advances=[0-9]+ state=(ready|running|zombie)",
    r"tasks: enabled=1 current=[0-9]+ switches=[0-9]+ pool=[0-9]+/[0-9]+ zombies=[0-9]+",
    r"idle +saves=[0-9]+ resumes=[0-9]+ advances=0 state=ready",
]
for p in pats:
    if not re.search(p, ser):
        sys.exit("FAIL: ERE absent: %s" % p)
print("lifecycle ERE ok")
PY
