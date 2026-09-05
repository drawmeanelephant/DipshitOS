# live-m16-image.spec -- claim 3805 (Milestone 16, Card C1) class-B gate:
#
# the SEGMENTED DSK3 user image format verified on real Apple silicon
# Virtualization.framework hardware.
#
# GLOBALS.BIN is the first segmented image: a read-only W^X text region
# (28 KiB — past the OLD 16 KiB exec bound, wishlist 15), a writable
# `.data` global, and a zero-filled 4 KiB `.bss` global (the M15 JINGLE
# finding reversed: EL0 writable globals exist now). The program reads its

vgate_name live-m16-image "claim 3805 (Milestone 16, Card C1) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GLOBALS.BIN
EOF

vgate_file script2.txt <<'EOF'
echo m16-image-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "globals: data bss ok" --script-expect "m16-image-live-ok" --timeout 90

vgate_assert 01 serial-absent 'exec: loaded GLOBALS.BIN size=0x0000000000007000'
vgate_assert 01 serial-contains 'exec: loaded GLOBALS.BIN'
vgate_assert 01 serial-absent 'data=0x0000000000001010 datapages=2'
vgate_assert 01 serial-contains 'globals: data bss ok'
vgate_assert 01 serial-contains 'tasks user-exec exited status=42'
vgate_assert 01 serial-contains 'm16-image-live-ok'
vgate_assert 01 serial-contains 'exec: loaded GLOBALS.BIN|globals:|user-exec exited'
vgate_assert 01 serial-absent '[EXC] parking:'
