# live-virtio-e2e.spec -- claim 0680 (issue #523 item 3 capstone, the
#
# acceptance row verbatim): ONE headless run proves a gate can DRIVE guest
# input AND READ guest output through the custom-virtio control plane
# end-to-end -- no CGEvent/NSEvent synthesis, no screenshot scraping
# anywhere in the critical path.
#
# Input side (claims 9588/9367 machinery): the runner types `input\n` as
# HID-shaped kind-1 messages into the guest's pre-armed queue-3 pool. The

vgate_name live-virtio-e2e "claim 0680 (issue #523 item 3 capstone, the"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-e2e.txt <<'EOF'
echo e2e-pre
EOF

vgate_file script-e2e2.txt <<'EOF'
exec WINLOOP.BIN
EOF

vgate_file script-e2e3.txt <<'EOF'
echo e2e-done
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --cvc-console-file '$RUN_DIR/cvc-console.log' --snapshot-after "winloop: present ok" --script '$RUN_DIR/script-e2e.txt' --input-string "input"$'\n' --input-string-after "e2e-pre" --script2 '$RUN_DIR/script-e2e2.txt' --script2-after "events=6" --script2-delay 2 --script3 '$RUN_DIR/script-e2e3.txt' --script3-after "winloop: present ok" --script3-delay 25 --script-expect "e2e-done" --timeout 180

vgate_assert 01 serial-contains 'winloop: present ok'
vgate_assert 01 serial-contains 'cvspike: q3 armed bufs='
vgate_assert 01 serial-contains 'cvspike: q2 ok=1'
vgate_assert 01 serial-contains 'gpu: setup ok scanout='
vgate_assert 01 serial-contains 'e2e-done'
vgate_assert 01 serial-contains 'events=6'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'screen-snap-*.raw' <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb').read()
assert len(data) == 1280 * 720 * 4, len(data)
w, h = 1280, 720
colors = set()
bright = dark = 0
for y in range(0, h, 2):          # stride 2: half-frame sample, still ~460k px
    row = data[y * w * 4:(y + 1) * w * 4]
    for x in range(0, w, 2):
        b, g, r = row[x*4], row[x*4+1], row[x*4+2]
        colors.add((b, g, r))
        lum = (r * 299 + g * 587 + b * 114) // 1000
        if lum > 200: bright += 1
        elif lum < 60: dark += 1
print(f"{len(colors)} {bright} {dark}")
PY

