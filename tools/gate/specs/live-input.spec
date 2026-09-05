# live-input.spec -- USB XHCI keyboard input on VZ (classic synthesized + custom-virtio)

vgate_name live-input "USB XHCI keyboard input on VZ (claim 6050 + 9588)"
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
echo i3-serial-ok
EOF

vgate_file script-virtio.txt <<'EOF'
echo i3-virtio-pre
EOF

# --- Phase 1: synthesized NSEvent input ---
vgate_run A -- \
    --input --display \
    --script '$RUN_DIR/script.txt' \
    --input-string "input"$'\n' --input-string-after "userspace: el0=1" \
    --script-expect "input: armed=" \
    --timeout 70

vgate_assert A serial-contains "input: armed"
vgate_assert A serial-contains "events=6"
vgate_assert A serial-absent "[EXC] parking:"

# --- Phase 2: custom-virtio INPUT queue ---
vgate_run B -- \
    --via-virtio \
    --script '$RUN_DIR/script-virtio.txt' \
    --input-string "input"$'\n' --input-string-after "i3-virtio-pre" \
    --script-expect "input: armed=" \
    --timeout 90

vgate_assert B serial-contains "input: armed"
vgate_assert B serial-contains "events=6"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B output-contains "KEY-SEQ"
