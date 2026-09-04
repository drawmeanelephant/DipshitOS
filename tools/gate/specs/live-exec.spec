# live-exec.spec -- a real user program (USER.BIN) loaded from the ESP
# through the FAT path and entered at EL0: load line, EL0 markers, and
# the exit/reap lifecycle closing, shell left responsive.
# Mirrors tools/verify-live-exec.sh (claim 6783).

vgate_name live-exec "load + exec USER.BIN from the ESP at EL0"
vgate_share seed
vgate_repeat 1 BOOTS
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
ls
exec USER.BIN
echo rx-exec-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'USER.BIN' 2
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-exact 'rx-exec-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
# Legacy -Fc = 1: exactly one line CONTAINING the needle (substring, not
# whole-line: markers can share a line with the prompt tail).
need = [
    "exec: loaded USER.BIN size=",
    "user: hello from the ESP",
    "user: exec ok",
    "tasks user-exec exited status=43",
]
bad = [(n, sum(1 for l in lines if n in l)) for n in need]
bad = [(n, c) for n, c in bad if c != 1]
if bad:
    sys.exit("FAIL: exec markers not exactly-once: %s" % bad)
print("exec markers exactly-once ok")
PY
