# live-wnd8-unsaved-drain.spec -- WMS8 Gate 4: unsaved-changes dialog drains into WND.BIN
#
# M66c follow-on (#1485): the client is GOEDIT.ELF, not the deleted Zig
# notepad. GOEDIT answers WIN_UNSAVED (kind 17) by publishing the buffer and
# exiting, and answers plain WIN_CLOSE (kind 8) by exiting WITHOUT writing - an
# editor's buffer is published by Ctrl-S or by an explicit Save, never silently
# by a close. That is the client contract these two boots assert.
#
# The click coordinates moved with the app: GOEDIT opens at (32,32) 512x384 where
# the Zig notepad declared (56,56), and the shim's close box is
# `[x + w - 16, x + w - 4) x [y, y + title_h)` (kernel/src/driving_award.zig), so
# its centre is (534, 40) instead of (558, 64). The dialog's own buttons are
# screen-fixed at 1280x720 and do not move.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goedit.sh   ->  .build/go/GOEDIT.ELF

vgate_name live-wnd8-unsaved-drain "WMS8 Gate 4: unsaved-changes dialog drains into WND.BIN"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec GOEDIT.ELF
EOF

vgate_file s2-A.txt <<'EOF'
dui unsaved 2 1
wm
echo dirty-a
EOF

vgate_file s3-A.txt <<'EOF'
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec GOEDIT.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui unsaved 2 1
wm
echo dirty-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
echo unsaved-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
print("staged GOEDIT.ELF into share (%d bytes) and %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOEDIT.ELF")), seed, os.path.getsize(seed)))
PY

# --- boot A: shim (no WM) -- dirty close is immediate, no dialog ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "goedit: present" --script2-delay 15 \
    --pointer-virtio "534,40,c" --pointer-virtio-after "dirty-a" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "dirty-a" --script3-delay 20 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui unsaved: id=2 flag=1"
vgate_assert A serial-contains "goedit: close"
vgate_assert A serial-absent "wnd: unsaved-dialog"
vgate_assert A serial-absent "goedit: win_unsaved"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: WM-driven unsaved-changes dialog ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "goedit: present" --script2-delay 15 \
    --pointer-virtio "534,40,c;660,390,c" --pointer-virtio-after "dirty-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "dirty-go" --script3-delay 20 \
    --script-expect "unsaved-done" --timeout 260

vgate_assert B serial-contains "wnd: unsaved-dialog"
vgate_assert B serial-contains "wnd: unsaved-discard"
vgate_assert B serial-contains "goedit: close"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dialog=[1-9][0-9]*', ser), "dialog check failed"
assert not re.search(r'wnd: (grab|drag|drop)', ser), "drag detected on close click"
PY
