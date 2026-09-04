# live-tasks.spec -- tick-driven round-robin: the worker demonstrably
# advances across timer ticks and the shell stays responsive. Mirrors
# tools/verify-live-tasks.sh (claim 5275). The row-shape checks are ERE in
# the original, so they ride the python escape hatch with identical
# patterns (see SPEC.md).

vgate_name live-tasks "round-robin tasks: worker advances, shell responsive"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: tasks / echo rx-tasks-ok; expect worker report line"

vgate_file script.txt <<'EOF'
tasks
echo rx-tasks-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'tasks worker advances=' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'interrupts: gic='
vgate_assert 01 serial-contains 'tasks: enabled=1'
vgate_assert 01 serial-contains 'rx-tasks-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Exactly the legacy pass rule (claim 5275): shell row, worker row, and
# the worker report. advances/heartbeat/switches shapes are diagnostic
# only in the original and stay out of the verdict here too.
need = [
    r"shell +saves=[0-9]+ resumes=[0-9]+ advances=0",
    r"worker +saves=[0-9]+ resumes=[0-9]+ advances=[0-9]+",
    r"tasks worker advances=[1-9][0-9]*",
]
missing = [p for p in need if not re.search(p, ser)]
if missing:
    sys.exit("FAIL: task-row patterns absent: %s" % missing)
print("task rows ok: shell/worker/report shapes hold")
PY
