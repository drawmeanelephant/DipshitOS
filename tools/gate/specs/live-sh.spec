# live-sh.spec -- M45 card SH2 class-B gate (issue #1078, ADR 0021 D2/D3),
# retargeted to GOSH by M68b (#1450).
#
# The gate's subject is the *shell*, not the binary that hosts it: an EL0
# shell opens /dev/tty, attaches the SERIAL console, prompts, and dispatches
# through its core. A scripted burst proves the core live: `echo` (builtin),
# `cd /data` + `$PWD` expansion, external `status43` resolved
# case-insensitively (status43 -> STATUS43.BIN) and run foreground, then
# Up-history re-runs it (status43: alive twice). Markers are single writes.
# `GOSH.ELF serial` is the Go front-end owner of that console
# (sys_tty_attach selector 1, ADR 0020), so every assert is unchanged except
# the binary and its marker prefix. Boot default unchanged.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-sh "#1078 SH2 userland shell: builtins, cd, external app + Up-history over /dev/tty"
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
# The `cd /data` target must actually EXIST on the share, or the assert
# below is weaker than it reads. SH.BIN's `cd` was pure shell-local
# bookkeeping (user/src/lib/shell.zig: "pwd/cd track the shell-local cwd"),
# so it accepted any string and `PWD=/data` passed for a path that was not
# there at all. GOSH verifies the directory through sys_dir_list before it
# moves, which is the behavior the M49 bar wants, so the gate has to hand
# it a real directory instead of a name.
os.makedirs(os.path.join(share, "data"), exist_ok=True)
print("staged GOSH.ELF (%d bytes) + data/ into share" % os.path.getsize(src))
PY

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
# echo sh-echo-ok; cd /data; echo PWD=$PWD; run status43; then Up + Enter to
# recall and re-run the last command from history.
seq = b"echo sh-echo-ok\rcd /data\recho PWD=$PWD\rstatus43\r\x1b[A\r"
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(seq)
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script-expect 'status43: alive' --script-expect-tail 16 --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'sh-echo-ok'
vgate_assert 01 serial-contains 'PWD=/data'
vgate_assert 01 serial-contains 'status43: alive'
vgate_assert 01 serial-count 'status43: alive' 2
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'
