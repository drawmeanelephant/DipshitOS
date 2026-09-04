# live-file-browser.spec -- claim 4046 (Milestone 13 B4): desktop composition on VZ.
# DESKTOP.BIN reads manifest apps=23 from /host/APPS.TXT, navigates to FILE.BIN,
# launches it via sys_exec (slot 28). FILE.BIN lists /host (7 entries) and opens
# the selected entry (APPS.TXT) read-only via sys_file_open/read (slots 23/24).

vgate_name live-file-browser "Milestone 13 B4: desktop composition on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/DESKTOP.BIN", share)
shutil.copy("zig-out/bin/FILE.BIN", share)
shutil.copy("image/apps.txt", os.path.join(share, "APPS.TXT"))
with open(os.path.join(share, "README.TXT"), "w") as f:
    f.write("VirelaiOS general filesystem readme\n")
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("general data volume contents: 1234567890\n")
PY

vgate_file script.txt <<'EOF'
exec DESKTOP.BIN
EOF

vgate_file script2.txt <<'EOF'
echo done-file-sweep
syscalls
EOF

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --input-chords 'down,down,down,down,down,down,down,down,return,return' --input-chords-after 'desktop: menu ready' --input-chords-delay 2.0 --chords-view --script2 '$RUN_DIR/script2.txt' --script2-after 'file: view APPS.TXT' --script-expect 'done-file-sweep' --timeout 120

vgate_assert 01 serial-contains 'desktop: manifest apps=23'
vgate_assert 01 serial-contains 'desktop: launch FILE.BIN'
vgate_assert 01 serial-contains '28 sys_exec calls=1'
vgate_assert 01 serial-contains 'file: ready'
vgate_assert 01 serial-contains 'file: listing 7 entries'
vgate_assert 01 serial-contains '27 sys_dir_list calls=2'
vgate_assert 01 serial-contains 'file: open APPS.TXT'
vgate_assert 01 serial-contains 'file: view APPS.TXT'
vgate_assert 01 serial-contains '23 sys_file_open calls=10'
vgate_assert 01 serial-contains '24 sys_file_read calls=3'
vgate_assert 01 serial-contains 'done-file-sweep'
vgate_assert 01 serial-absent '[EXC] parking'
