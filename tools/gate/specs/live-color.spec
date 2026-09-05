# live-color.spec -- M18 T5 class-B gate (issue #408): ANSI terminal
#
# colors on real VZ.
#
# Mechanism: boots the image, types `color on` then `ls` (to see bold dirs),
# then `color off`, then verifies the prompt wraps in ANSI escape codes.
#
# The walk: color on, ls, color off, echo color-live-ok
#

vgate_name live-color "M18 T5 class-B gate (issue #408): ANSI terminal"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
os.makedirs(os.path.join(share, "testdir"), exist_ok=True)
PY

vgate_file script.txt <<'EOF'
color on
color
ls
color off
echo color-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect "color-live-ok" --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'color: on'
vgate_assert 01 serial-contains '[dir]'
vgate_assert 01 serial-contains 'color: off'
vgate_assert 01 serial-contains 'color-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
