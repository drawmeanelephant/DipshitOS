# live-pointer-virtio.spec -- claim 9367 (issue #523 item 3
#
# productionization; attacks issue #151) class-B gate: POINTER injection
# over the custom-virtio INPUT queue drives cursor motion + click-to-focus,
# HEADLESS.
#
# WHY THIS EXISTS: every synthesized host pointer route fails at the
# claim-4769 activation wall -- VZ only translates host input for its KEY
# window, so the pointer-focus proof was class-C-only (real mouse, claim

vgate_name live-pointer-virtio "claim 9367 (issue #523 item 3"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-ptr.txt <<'EOF'
exec WINLOOP.BIN
EOF

vgate_file script-ptr2.txt <<'EOF'
dui raise 2
echo ptrcv-raised
EOF

vgate_file script-ptr3.txt <<'EOF'
dui hit 200 150
input
echo ptr-cv-done
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script-ptr.txt' --script2 '$RUN_DIR/script-ptr2.txt' --script2-after "winloop: present ok" --pointer-virtio "200,150;200,150,c;640,600;640,600,c" --pointer-virtio-after "ptrcv-raised" --script3 '$RUN_DIR/script-ptr3.txt' --script3-after "ptrcv-raised" --script3-delay 30 --script-expect "ptr-cv-done" --timeout 180

vgate_assert 01 serial-contains 'input: armed=0 '
vgate_assert 01 serial-contains 'ptr-reports='
vgate_assert 01 serial-contains 'dui: pointer focus='
vgate_assert 01 serial-contains 'cvspike: q3 armed bufs='
vgate_assert 01 serial-contains 'cvspike: q2 ok=1'
vgate_assert 01 serial-contains 'winloop: present ok'
vgate_assert 01 serial-contains 'ptr-cv-done'
vgate_assert 01 serial-contains 'gpu: setup ok scanout='
vgate_assert 01 serial-absent '[EXC] parking:'
