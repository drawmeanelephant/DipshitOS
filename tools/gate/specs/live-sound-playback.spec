# live-sound-playback.spec -- claim 5877 (Milestone 15 Card A2): PCM playback on VZ.
# The runner boots with --sound and executes `beep 440 300`. The guest drives virtio-snd
# PCM_INFO -> PCM_SET_PARAMS -> PCM_PREPARE -> PCM_START -> TX submission (4096-B
# periods of FLOAT/stereo/48 kHz) -> drain -> PCM_STOP -> PCM_RELEASE.

vgate_name live-sound-playback "M15 A2 PCM playback on VZ"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
beep 440 300
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'beep: ok' --timeout 150

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'snd: pre-rearm st=0f'
vgate_assert 01 serial-contains 'beep: info st=0x0000000000008000'
vgate_assert 01 serial-contains 'formats=0x00000000000a0020'
vgate_assert 01 serial-contains 'rates=0x0000000000000480'
vgate_assert 01 serial-contains 'ch=1..2 dir=0'
vgate_assert 01 serial-contains 'beep: params fmt=19 rate=7 ch=2'
vgate_assert 01 serial-contains 'st=0x0000000000008000 prepare=0x0000000000008000 start=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: tx submitted=115200 drained=115200 frames=14400'
vgate_assert 01 serial-contains 'pcm_status=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: stop=0x0000000000008000 release=0x0000000000008000'
vgate_assert 01 serial-contains 'beep: ok'
vgate_assert 01 serial-absent '[EXC] parking'
