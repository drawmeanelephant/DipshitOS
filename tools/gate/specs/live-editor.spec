# live-editor.spec -- M23 E2-E5 class-B gate:
#
# undo/redo, goto-line, multi-file tabs on real VZ hardware.
#
# Mechanism: boots the production image, execs EDIT.BIN from the monitor,
# waits for the app to be ready, sends Ctrl chords to exercise the new
# features, and asserts the serial markers prove they happened.
#
# The walk:

vgate_name live-editor "M23 E2-E5 class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec EDIT.BIN
EOF

vgate_run 01 -- --display --screen "$(art editor-screen)" --via-virtio --script '$RUN_DIR/script.txt' --input-chords "f,n,space,m,a,i,n,space,m,a,i,n,ctrl-d,X,Y,ctrl-z,ctrl-l,ctrl-f,escape,ctrl-h,escape,ctrl-shift-d,ctrl-shift-p,escape,ctrl-r,escape,ctrl-shift-t,ctrl-b,ctrl-shift-f,return,ctrl-s,ctrl-t,ctrl-g" --input-chords-after "edit: ready" --script-expect "edit: goto-open" --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'edit: ready'
vgate_assert 01 serial-contains 'edit: undo'
vgate_assert 01 serial-contains 'edit: toggle-lines'
vgate_assert 01 serial-contains 'edit: find-open'
vgate_assert 01 serial-contains 'edit: replace-open'
vgate_assert 01 serial-contains 'edit: delete-line'
vgate_assert 01 serial-contains 'edit: palette-open'
vgate_assert 01 serial-contains 'edit: recent-open'
vgate_assert 01 serial-contains 'edit: theme-cycle'
vgate_assert 01 serial-contains 'edit: bookmark-toggle'
vgate_assert 01 serial-contains 'edit: multi-cursor'
vgate_assert 01 serial-contains 'edit: tree-toggle'
vgate_assert 01 serial-contains 'edit: tree-open-ok'
vgate_assert 01 serial-contains 'edit: save-ok'
vgate_assert 01 serial-contains 'edit: tab-open'
vgate_assert 01 serial-contains 'edit: goto-open'
vgate_assert 01 serial-absent '[EXC] parking:'
