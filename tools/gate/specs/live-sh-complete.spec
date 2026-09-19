# live-sh-complete.spec -- M45 card SH3 class-B gate (issue #1079, ADR 0021 D6),
# retargeted to GOSH by M68b (#1450).
#
# The shell's line editor handles Tab completion and Ctrl+R
# reverse-i-search. The script runs status43 once (history entry),
# Tab-completes `hel` -> `help` (builtin) and runs it (`builtins:`), then
# Ctrl+R types `status`, recalls the status43 history entry, accepts and
# re-runs it (status43: alive twice). Markers are single writes. Boot default
# unchanged: nothing attaches until the shell does.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-sh-complete "#1079 SH3 Tab completion + Ctrl+R reverse-i-search on the userland shell"
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
print("staged GOSH.ELF (%d bytes) into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# Run status43 (history); Tab-complete hel -> help + Enter; then Ctrl+R,
# query "status", accept (Enter) and run (Enter).
seq = b"status43\rhel\t\r\x12status\r\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script-expect 'status43: exiting' --script-expect-tail 20 --timeout 100

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'builtins:'
vgate_assert 01 serial-contains 'reverse-i-search'
vgate_assert 01 serial-contains 'status43: alive'
vgate_assert 01 serial-count 'status43: alive' 2
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
