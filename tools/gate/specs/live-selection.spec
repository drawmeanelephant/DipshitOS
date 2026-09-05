# live-selection.spec -- milestone-eighteen card T2 class-B gate (issue #405):
#
# scrollback text selection, copy, and paste on real VZ.
#
# Mechanism: the production image is booted with the runner's scripted-input
# mode (--script / --script2 / --script-expect, claim-6684). Phase 1
# (--script) fills the scrollback with echo lines. Phase 2 types PageUp and
# Up through the SYNTHESIZED KEYBOARD as NSEvents (--input-chords, claims
# 1809 + 5093) — the real scroll keys enter selection and extend the range.

vgate_name live-selection "milestone-eighteen card T2 class-B gate (issue #405):"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo line-01
echo line-02
echo line-03
echo line-04
echo line-05
echo line-06
echo line-07
echo line-08
echo line-09
echo line-10
echo line-11
echo line-12
echo line-13
echo line-14
echo line-15
echo line-16
echo line-17
echo line-18
echo line-19
echo line-20
echo fill-ready
EOF

# The modifier chords (Ctrl+C = 0x03, Ctrl+V = 0x16) cannot be typed
# through VZ's synthesized keyboard — the legacy gate wrote them to
# artifacts/live-selection-keys.txt at runtime; the spec carries the same
# bytes as a hermetic $RUN_DIR fixture (the claim-6684 script2 channel).
vgate_file keys.txt <<'EOF'
echo 

input
echo selection-live-ok
EOF

vgate_run 01 -- --input --display --script '$RUN_DIR/script.txt' --input-chords "pageup,up" --input-chords-after "fill-ready" --input-chords-delay 2.0 --script2 '$RUN_DIR/keys.txt' --script2-after "fill-ready" --script2-delay 12 --script-expect "selection-live-ok" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'fill-ready'
vgate_assert 01 serial-contains 'copied'
vgate_assert 01 serial-contains 'input: armed=1 fifo=0/64 dropped=0 events=2'
vgate_assert 01 serial-contains 'selection-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
