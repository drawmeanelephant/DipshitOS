# live-text-search.spec -- milestone-twenty card U3 class-B gate (text search in apps)
# M60 / #1374: boot B (exec FILE.BIN filename filter) retired with Zig FILE.BIN.
# M66c follow-on (#1485): the walk moved from the retired Zig notepad to
# GOEDIT.ELF, which gained the find bar and the goto-line bar for exactly this
# walk (user/go/edit). The document, the chords and both result markers are
# unchanged; the binary, the chord-release marker (`goedit: present`) and the
# marker prefix are what moved.

vgate_name live-text-search "M20 U3 -- GOEDIT.ELF find/goto on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/SEED.TXT
EOF

vgate_file settle-A.txt <<'EOF'
dui focus 0
echo m20-goedit-search-ok
EOF

# Host prerequisite (fails the gate honestly when missing):
#   bash tools/go/build-goedit.sh   ->  .build/go/GOEDIT.ELF
# The fixture is staged EMPTY on purpose: the walk types the whole document, so
# a seeded body would move line 2 and the asserted offset with it.
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
with open(seed, "wb"):
    pass
print("staged GOEDIT.ELF into share (%d bytes) and an empty %s" %
      (os.path.getsize(os.path.join(share, "GOEDIT.ELF")), seed))
PY

# --- boot A: the find bar + Ctrl+G goto line ---
# The walk types "hello\nworld\ntext", finds `wor` (one match of one) and jumps
# to line 2, which starts at offset 6.
vgate_run A -- \
    --screen '$RUN_DIR/gpu-screen-A' \
    --script '$RUN_DIR/script-A.txt' \
    --input-chords "h,e,l,l,o,return,w,o,r,l,d,return,t,e,x,t,ctrl-f,w,o,r,return,ctrl-g,2,return" --input-chords-after "goedit: present" \
    --script2 '$RUN_DIR/settle-A.txt' --script2-after "goedit: goto line=2 offset=6" --script2-delay 2 \
    --script-expect "m20-goedit-search-ok" --timeout 150

vgate_assert A serial-contains "goedit: present"
vgate_assert A serial-contains "goedit: find 'wor' hit=1/1"
vgate_assert A serial-contains "goedit: goto line=2 offset=6"
vgate_assert A serial-contains "m20-goedit-search-ok"
vgate_assert A serial-absent "[EXC] parking:"
