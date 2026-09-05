# live-sound-control.spec -- claim 9297 (M15 follow-up): stream-state control on VZ.
# Proves stream-state control (volume 0..100 + mute) applied as in-place gain at TX
# submit choke point: monitor control sets vol/mute, muted beep still drains exactly,
# unmuted beep drains at new volume, and CHIME.BIN mutates kernel state via EL0 seam
# (ADR 0007 slots 44/45).

vgate_name live-sound-control "M15 stream-state control on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sound volume 30
sound
sound mute on
beep 440 200
sound mute off
beep 660 150
exec CHIME.BIN
EOF

vgate_file script2.txt <<'EOF'
sound
syscalls
echo control-live-ok
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'chime: done' --script2-delay 3 --script-expect 'control-live-ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'sound: volume=30'
vgate_assert 01 serial-contains 'sound: vol=30 mute=0'
vgate_assert 01 serial-contains 'sound: mute=on'
vgate_assert 01 serial-contains 'beep: tx submitted=76800 drained=76800 frames=9600'
vgate_assert 01 serial-contains 'pcm_status=0x0000000000008000'
vgate_assert 01 serial-contains 'sound: mute=off'
vgate_assert 01 serial-contains 'beep: tx submitted=57600 drained=57600 frames=7200'
vgate_assert 01 serial-contains 'chime: vol=50 mute=0'
vgate_assert 01 serial-contains 'chime: done'
vgate_assert 01 serial-contains 'tasks user-exec exited status=0'
vgate_assert 01 serial-contains 'sound: vol=50 mute=0'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=66'
vgate_assert 01 serial-contains '44 sys_audio_volume calls=1'
vgate_assert 01 serial-contains '45 sys_audio_mute calls=1'
vgate_assert 01 serial-contains '43 sys_audio_play calls=30'
vgate_assert 01 serial-contains 'control-live-ok'
vgate_assert 01 serial-absent '[EXC] parking'
