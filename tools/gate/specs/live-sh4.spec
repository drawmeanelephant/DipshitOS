# live-sh4.spec -- M45 card SH4 class-B gate (issue #1080, ADR 0021 D6),
# retargeted to GOSH by M68b (#1450).
#
# The operators, over the SERIAL front-end (`GOSH.ELF serial`), anchored on
# markers that NEVER appear in typed text (a heartbeat can split a typed
# line, so counting echoed markers is unreliable):
#   cd /data ; env | cat        -> PWD=/data  (left output through the kernel
#                                  pipe slots 56/57 into cat's stdin)
#   help > HELP.TXT ; cat < ... -> builtins: (redirect capture to the share,
#                                  then read back; neither typed line contains
#                                  "builtins:")
# Boot default unchanged; markers single writes.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh   ->  .build/go/GOSH.ELF

vgate_name live-sh4 "#1080 SH4 pipes + redirection on the userland shell"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
# `cd /data` must land on a directory that really exists: GOSH verifies the
# target through sys_dir_list before it moves (SH.BIN's `cd` was pure
# shell-local bookkeeping and accepted any string).
os.makedirs(os.path.join(share, "data"), exist_ok=True)
print("staged GOSH.ELF (%d bytes) + data/ into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
seq = b"cd /data\renv | cat\rhelp > HELP.TXT\rcat < HELP.TXT\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script-expect 'builtins:' --script-expect-tail 6 --timeout 75

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'PWD=/data'
vgate_assert 01 serial-contains 'builtins:'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
