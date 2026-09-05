# live-unicode.spec -- milestone-twenty cards U2/U3/U11 class-B gate
#
# (issues #307/#308/#316): Unicode glyphs render on the terminal and the
# missing-glyph fallback is observable over serial.
#
# Mechanism: boots the production image and drives the walk over serial.
# `text put` renders UTF-8 into the framebuffer text layer through the
# SAME putc/UTF-8 decoder the shell output path uses, then reports the
# flush result; `text fontdebug` exposes the missing-glyph counters:

vgate_name live-unicode "milestone-twenty cards U2/U3/U11 class-B gate"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
text fontdebug on
text put café
text fontdebug
text putraw 中文
text fontdebug
echo m20-unicode-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-expect "m20-unicode-ok" --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-contains 'text put: ok'
vgate_assert 01 serial-absent 'missing=0'
vgate_assert 01 serial-contains 'missing='
vgate_assert 01 serial-contains 'last=U+6587'
vgate_assert 01 serial-contains 'm20-unicode-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
