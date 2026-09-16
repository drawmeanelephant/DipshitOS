# go-edit.spec -- M58b (issue #1306) class-B gate: a Go editor opens a share
# file, edits the buffer, saves it, and closes, full-viewport inside Zig TABWM.
#
# user/go/edit is a tabapp client: init -> declare (kind-8 WM_RPC) -> read the
# seeded /host/EDIT/SEED.TXT -> accept injected keystrokes into the buffer
# (Win_DOWN arg1 is the Unicode codepoint) -> Ctrl-S writes the buffer back ->
# WIN_CLOSE exits. Zig EDIT.BIN / NOTEPAD.BIN are untouched; kernel untouched.
#
# The load-bearing evidence is NOT only the app's own markers: the run's last
# assert reads the share file back ON THE HOST and requires it to equal the
# seed plus the typed characters, so a save that reported success without
# writing the bytes cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goedit.sh   ->  .build/go/GOEDIT.ELF
#
# exec-order: assert-proven -- the run ends on `rx-goedit-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `goedit: saved `; a program that never ran cannot pass.

vgate_name go-edit "issue #1306 M58b: a Go editor opens, edits and saves a share file in Zig TABWM on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/SEED.TXT
EOF

# The close is driven from the harness after the app's own `goedit: saved `
# (the stage gate), so the bytes are on the share before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-goedit-ok
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
      (os.path.getsize(os.path.join(share, "GOEDIT.ELF")),
       seed, os.path.getsize(seed)))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'X,Y,Z,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-goedit-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'goedit: open id='
vgate_assert 01 serial-contains 'goedit: declare accepted'
# The seeded fixture was read (10 bytes: "seed-line\n").
vgate_assert 01 serial-contains 'goedit: read /host/EDIT/SEED.TXT n=10'
# The first frame is on the scanout (this is also the chord-release stage).
vgate_assert 01 serial-contains 'goedit: present'
# The injected keystrokes reached the buffer.
vgate_assert 01 serial-contains 'goedit: dirty'
# Ctrl-S wrote the buffer back (13 bytes: the seed plus the three typed chars).
vgate_assert 01 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=13'
vgate_assert 01 serial-contains 'goedit: close'
vgate_assert 01 serial-contains 'goedit OK'
vgate_assert 01 serial-contains 'rx-goedit-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the share file on the HOST must now hold exactly the
# seed plus the typed characters. A save that reported success without writing
# the bytes cannot pass this.
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "SEED.TXT")
want = b"seed-line\nXYZ"
got = open(path, "rb").read()
if got != want:
    print("SAVED CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("saved content verified on the host: %r (%d bytes)" % (got, len(got)))
PY
