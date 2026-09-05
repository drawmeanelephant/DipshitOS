# live-time.spec -- M22 D13 (issue #336) class-B gate:
#
# the `time <command>` timing wrapper on real VZ hardware.
#
# Mechanism: boots the production image and runs `time sysinfo`. The
# dashboard's map/allocator/storage walk is the heaviest synchronous
# monitor command (~250 ms observed on VZ), so the elapsed measurement
# MUST be nonzero. (`exec` is asynchronous on this kernel — `time exec X`
# measures only the load, ticks 0; there is no sleep/builtin that blocks.)

vgate_name live-time "M22 D13 (issue #336) class-B gate:"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
time sysinfo
echo rx-time-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect "rx-time-ok" --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
if not re.search(r'(?m)^real\s+[0-9]+m[0-9]+s', ser):
    print("real time line missing", file=sys.stderr); sys.exit(1)
if not re.search(r'(?m)^ticks\s+[1-9][0-9]*', ser):
    print("ticks line missing", file=sys.stderr); sys.exit(1)
PY
vgate_assert 01 serial-contains 'rx-time-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
