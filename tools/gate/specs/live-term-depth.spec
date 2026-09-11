# live-term-depth.spec -- M49 card SD5 class-B gate (issue #1132).
#
# TERM.BIN first-class window terminal: a share script prints 30 numbered
# lines into the kernel presentation grid, the host pointer (custom-virtio
# kind-2, guest pixels) drag-selects a row in the window's client area, and
# the Ctrl+Shift+C chord copies the selection into the shared clipboard.
# The monitor `clip` command then prints the copied bytes on the serial
# console — observed selection/copy. Reflow/scrollback math is class-A
# (kernel/src/terminal.zig tests) with the paint-path width sync.
# Boot default is unchanged (the serial console still belongs to the
# monitor while TERM.BIN owns only its window).

vgate_name live-term-depth "#1132 SD5: TERM.BIN pointer selection + Ctrl+Shift+C copy through the kernel grid"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TERM.BIN
EOF

vgate_file clip.txt <<'EOF'
clip
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
lines = ["echo LINE-%02d" % i for i in range(30)]
with open(os.path.join(share, "BIG.SH"), "w") as f:
    f.write("\n".join(lines) + "\n")
PY

vgate_run 01 -- --display --input --via-virtio --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --input-string 'source BIG.SH'$'\n' \
    --input-string-after 'term: attached' \
    --pointer-virtio "68,76;68,76,d;124,76;124,76,u" \
    --pointer-virtio-after 'term: line source BIG.SH' \
    --input-chords "ctrl-shift-c,e,c,h,o,space,a,f,t,e,r,return" \
    --input-chords-after 'dui: term sel end' \
    --script2 '$RUN_DIR/clip.txt' \
    --script2-after 'term: line echo after' \
    --script-expect 'clip: LINE-00' \
    --timeout 150

vgate_assert 01 serial-contains 'term: ready'
vgate_assert 01 serial-contains 'term: attached'
vgate_assert 01 serial-contains 'term: line source BIG.SH'
vgate_assert 01 serial-contains 'term: done status=0'
vgate_assert 01 serial-contains 'tty: copy 7 bytes'
vgate_assert 01 serial-contains 'clip: LINE-00'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_done = ser.find("term: done status=0")
i_copy = ser.find("tty: copy 7 bytes")
i_clip = ser.find("clip: LINE-00")
assert i_done >= 0, "BIG.SH did not finish"
assert i_copy > i_done, f"copy marker not after the script (done={i_done} copy={i_copy})"
assert i_clip > i_copy, f"clip read not after the copy (copy={i_copy} clip={i_clip})"
print("selection/copy ordering OK: term done < tty copy < clip read")
PY
