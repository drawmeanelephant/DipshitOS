# live-editing.spec -- milestone-eight card U2 class-B gate (claim 1809):
# ADR 0008 D2 line editor on real VZ hardware.

vgate_name live-editing "milestone-eight card U2 class-B gate -- line editor on real VZ"

vgate_file script.txt <<'EOF'
echo u2-serial-ok
EOF

vgate_setup_python <<'PY'
import os
path = os.path.join(os.environ["RUN_DIR"], "chords.txt")
with open(path, "wb") as f:
    f.write(b"cho u2chord\x01e\n")
    f.write(b"echo u2en\x01\x05d\n")
    f.write(b"echo u2killXXXX\x1b[D\x1b[D\x1b[D\x1b[D\x0b\n")
    f.write(b"JUNK\x15echo u2under\n")
    f.write(b"echo u2clear\x0c\n")
    f.write(b"echo NEVER\x03echo u2cancel\n")
PY

CHORDS="e,c,h,o,space,a,b,left,c,return,up,return,e,c,h,o,space,u,2,d,o,n,e,return"

vgate_run 01 -- \
    --input --display \
    --script '$RUN_DIR/script.txt' \
    --input-chords "$CHORDS" --input-chords-after "userspace: el0=1" \
    --script2 '$RUN_DIR/chords.txt' --script2-after "u2done" \
    --script-expect "u2cancel" \
    --timeout 240

vgate_assert 01 serial-contains 'input: armed'
vgate_assert 01 serial-contains 'u2-serial-ok'
vgate_assert 01 serial-exact 'acb' 2
vgate_assert 01 serial-exact 'u2done' 1
vgate_assert 01 serial-exact 'u2chord' 1
vgate_assert 01 serial-exact 'u2end' 1
vgate_assert 01 serial-exact 'u2kill' 1
vgate_assert 01 serial-exact 'u2under' 1
vgate_assert 01 serial-exact 'u2cancel' 1
vgate_assert 01 serial-exact 'NEVER' 0
vgate_assert 01 serial-contains '^C'
vgate_assert 01 output-contains 'input-chords: ENABLED'
vgate_assert 01 serial-absent '[EXC] parking:'
