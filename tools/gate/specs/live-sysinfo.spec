# live-sysinfo.spec -- M22 D9: sysinfo information dashboard on VZ.
# Renders every dashboard section: cpu, memory, allocator, scheduler, processes,
# storage (host_share armed per M34 HF6), network, graphics, input, and uptime.

vgate_name live-sysinfo "M22 D9: sysinfo information dashboard on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
sysinfo
echo rx-sysinfo-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-sysinfo-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'sysinfo: VirelaiOS AArch64 support snapshot'
vgate_assert 01 serial-contains '  cpu:        arch=aarch64'
vgate_assert 01 serial-contains '  memory:     descriptors='
vgate_assert 01 serial-contains '  allocator:  armed='
vgate_assert 01 serial-contains '  storage:    host_share=armed'
vgate_assert 01 serial-contains '  network:    virtio-net='
vgate_assert 01 serial-contains '  graphics:   gpu='
vgate_assert 01 serial-contains '  input:      xhci='
vgate_assert 01 serial-contains '  uptime:     ticks='
vgate_assert 01 serial-contains 'rx-sysinfo-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
