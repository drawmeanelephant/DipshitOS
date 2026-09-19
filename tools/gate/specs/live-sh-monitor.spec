# live-sh-monitor.spec -- M49 card SD1 class-B gate (issue #1128, ADR 0021 D1),
# retargeted to GOSH by M68b (#1450).
#
# `settings shell=sh` boots into the shell seat (the M45 SH8 login seam). The
# typed `monitor` builtin announces the handover, detaches the serial
# front-end, closes /dev/tty, and exits; the kernel monitor observes the
# detach and resumes reading the raw console — `version` answers with
# `virelai-kernel`. This proves the login shell is not a one-way door. Boot
# default (no SETTINGS.TXT) stays the monitor; the existing live-sh* gates
# cover it.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-sh-monitor "#1128 SD1: the login shell's monitor escape returns the raw console to the kernel monitor"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
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
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    # M66b (#1444): the `#v<N>` schema header is REQUIRED — a headerless file
    # is refused WHOLE and the compiled defaults (shell=monitor) stay in
    # force. This spec seeded a bare `shell=sh\n` and had been silently red
    # since M66b (class-B gates are not enforced in CI); M68b repaired it.
    f.write("#v2\nshell=sh\n")
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(b"monitor\r")
with open(os.path.join(run, "edit2.bin"), "wb") as f:
    f.write(b"version\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'gosh: attached' --script3 '$RUN_DIR/edit2.bin' --script3-after 'gosh: monitor' --script-expect 'virelai-kernel' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The seed was ACCEPTED: a refused SETTINGS.TXT would keep shell=monitor and
# the login handoff could not run at all.
vgate_assert 01 serial-absent 'SETTINGS.TXT refused'
vgate_assert 01 serial-contains 'login: shell=sh -> GOSH.ELF serial'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'gosh: monitor'
vgate_assert 01 serial-contains 'virelai-kernel'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_ready = ser.find("gosh: ready")
i_mon = ser.find("gosh: monitor")
i_ver = ser.find("virelai-kernel")
assert i_ready >= 0 and i_mon >= 0 and i_ver >= 0, "missing marker(s)"
assert i_ready < i_mon < i_ver, f"wrong order ready={i_ready} monitor={i_mon} version={i_ver}"
assert "login: shell=sh -> GOSH.ELF serial" in ser, "the login handoff did not run"
print("monitor escape ordering OK: gosh: ready < gosh: monitor < virelai-kernel")
PY
