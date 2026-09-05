# live-m15-composition.spec -- claim 3206 (Milestone 15, Card A4)
#
# class-B gate: the composition capstone on real Apple silicon VZ — the
# hearable milestone, in ONE VM session.
#
# The card: "Sound joins the desktop: a boot chime, and a sound fires on
# an existing event (window focus, a clipboard copy, or a timer tick) —
# audio composes with the M14 shared services." This gate proves all four
# layers of the milestone in a single boot:

vgate_name live-m15-composition "claim 3206 (Milestone 15, Card A4)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec CHIME.BIN
EOF

vgate_file script2.txt <<'EOF'
sound
syscalls
echo composition-live-ok
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "chime: done" --script2-delay 3 --script-expect "composition-live-ok" --timeout 150

vgate_assert 01 serial-contains 'chime: boot chime played (660+880)'
vgate_assert 01 serial-contains 'chime:'
vgate_assert 01 serial-contains 'sound: did=0x0000000000001059'
vgate_assert 01 serial-contains 'chime: info fmt=19 rate=7 ch=2'
vgate_assert 01 serial-contains 'chime: tick 1 seq='
vgate_assert 01 serial-contains 'chime: tick 1 seq='
vgate_assert 01 serial-contains 'chime: tick 2 seq='
vgate_assert 01 serial-contains 'chime: tick 3 seq='
vgate_assert 01 serial-contains 'chime: done'
vgate_assert 01 serial-contains 'tasks user-exec exited status=0'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=61'
vgate_assert 01 serial-contains '40 sys_timer_set calls=3'
vgate_assert 01 serial-contains '40 sys_timer'
vgate_assert 01 serial-contains '42 sys_audio_info calls=1'
vgate_assert 01 serial-contains '43 sys_audio_play calls=30'
vgate_assert 01 serial-contains '43 sys_audio'
vgate_assert 01 serial-contains 'composition-live-ok'
vgate_assert 01 output-contains 'SOUND:'
vgate_assert 01 serial-absent '[EXC] parking:'
