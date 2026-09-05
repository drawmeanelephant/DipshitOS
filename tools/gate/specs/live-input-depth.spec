# live-input-depth.spec -- audit follow-up (issue #117) class-B gate:
#
# the multi-TRB interrupt-IN depth re-test. The keyboard must deliver a typed
# command byte-exact with dropped=0 on the depth-8 arming.
#
# Background (issue #117 / claim 6050): I3 concluded "single-TRB arming is
# the correct shape" because a multi-TRB depth (8) experiment "wrapped the
# transfer ring at the 8th report and dropped everything after". That
# experiment ran against the PRE-U2 xhci_arm_intr, which computed the

vgate_name live-input-depth "audit follow-up (issue #117) class-B gate:"

vgate_file script.txt <<'EOF'
echo depth-serial-ok
EOF

vgate_run 01 -- --input --display --script '$RUN_DIR/script.txt' --input-chords "e,c,h,o,space,f,a,s,t,o,k,return,i,n,p,u,t,return" --input-chords-after "userspace: el0=1" --input-chords-delay 2.0 --script-expect "input: armed=1 fifo=0/64 dropped=0 events=18" --timeout 130

vgate_assert 01 serial-contains 'input: armed'
vgate_assert 01 serial-contains 'fastok'
vgate_assert 01 serial-contains 'dropped=0'
vgate_assert 01 serial-contains 'events=18'
vgate_assert 01 serial-contains 'kb-usage=0x28 kb-byte=0xa'
vgate_assert 01 serial-contains 'depth-serial-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
