# live-sh-profile.spec -- M49 card SD2 class-B gate (issue #1129),
# retargeted to GOSH by M68b (#1450).
#
# The unified shell startup order: STARTUP.SH first, then the optional
# host-share PROFILE.SH, both run once before the shell's first prompt. The
# gate seeds both files, execs the shell over the SERIAL front-end
# (`GOSH.ELF serial`), and asserts the outputs and their order
# (START-UP < PRO-FILE < the typed profile-done). GOSH implements the same
# shared order (main.go startupLines); `TERM.BIN` runs it too
# (lib/startup.zig); the kernel monitor's `.virelairc` stays monitor-scope
# (documented in docs/status.md).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh   ->  .build/go/GOSH.ELF

vgate_name live-sh-profile "#1129 SD2: the shell runs STARTUP.SH then PROFILE.SH before the first prompt"
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
with open(os.path.join(run, "share", "STARTUP.SH"), "w") as f:
    f.write("echo START-UP\n")
with open(os.path.join(run, "share", "PROFILE.SH"), "w") as f:
    f.write("echo PRO-FILE\n")
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(b"echo profile-done\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script-expect 'profile-done' --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'START-UP'
vgate_assert 01 serial-contains 'PRO-FILE'
vgate_assert 01 serial-contains 'profile-done'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_start = ser.find("START-UP")
i_profile = ser.find("PRO-FILE")
i_done = ser.find("profile-done")
assert i_start >= 0 and i_profile >= 0 and i_done >= 0, "missing marker(s)"
assert i_start < i_profile < i_done, f"wrong order startup={i_start} profile={i_profile} done={i_done}"
print("startup order OK: STARTUP.SH < PROFILE.SH < typed command")
PY
