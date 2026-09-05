# live-font-sizes.spec -- milestone-twenty card U1 class-B gate
#
# (issue #306): three font sizes on the terminal text layer.
#
# Mechanism: boots the production image and drives the walk over serial.
# The monitor `text` report prints rows/cols and the cell size, so the
# size switch is observable WITHOUT reading the framebuffer:
#   text            -> cell=8x8, cols=160, rows=90 (small baseline)
#   font medium     -> switches to 16x16

vgate_name live-font-sizes "milestone-twenty card U1 class-B gate"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
text
font medium
text
font large
text
font small
text
echo m20-font-ok
EOF

vgate_run 01 -- --screen artifacts/gpu-screen --script '$RUN_DIR/script.txt' --script-expect "m20-font-ok" --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'rows=90 cols=160 cell=8x8'
vgate_assert 01 serial-contains 'rows=45 cols=80 cell=16x16'
vgate_assert 01 serial-contains 'rows=30 cols=53 cell=24x24'
vgate_assert 01 serial-contains 'm20-font-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
