# live-sound-device.spec -- claim 6140 (Milestone 15 Card A1): virtio-snd transport on VZ.
# The runner boots with --sound. The guest discovers the virtio-snd device on PCI
# bus 0 (DID 0x1059, class 0x040100), negotiates features, arms the control queue,
# reaches DRIVER_OK (st=0x0f), re-arms post-MMU, and reports device config via `sound`.

vgate_name live-sound-device "M15 A1 virtio-snd transport on VZ"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sound
EOF

vgate_run 01 -- --sound --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect 'sound: cfg=' --timeout 90

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'snd: pre-rearm st=0f'
vgate_assert 01 serial-contains 'snd: rearm ok st=0f'
vgate_assert 01 serial-contains 'did=0x0000000000001059'
vgate_assert 01 serial-contains 'cls=0x0000000000040100'
vgate_assert 01 serial-contains 'st=0x000000000000000f'
vgate_assert 01 serial-contains 'qsz=0x0000000000000004'
vgate_assert 01 serial-contains 'sound: cfg=jacks=0 streams=0 chmaps=0'
vgate_assert 01 serial-absent '[EXC] parking'
