# live-sh-monitor.spec -- M49 card SD1 class-B gate (issue #1128, ADR 0021 D1).
#
# `settings shell=sh` boots into SH.BIN (the M45 SH8 login seam). The typed
# `monitor` builtin detaches the serial front-end, closes /dev/tty, and
# exits; the kernel monitor observes the detach and resumes reading the raw
# console — `version` answers with `virelai-kernel`. This proves the login
# shell is not a one-way door. Boot default (no SETTINGS.TXT) stays the
# monitor; the existing live-sh* gates cover it.

vgate_name live-sh-monitor "#1128 SD1: the SH.BIN monitor escape returns the raw console to the kernel monitor"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
EOF

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
with open(os.path.join(run, "share", "SETTINGS.TXT"), "w") as f:
    f.write("shell=sh\n")
with open(os.path.join(run, "edit.bin"), "wb") as f:
    f.write(b"monitor\r")
with open(os.path.join(run, "edit2.bin"), "wb") as f:
    f.write(b"version\r")
PY

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/edit.bin' --script2-after 'sh: attached' --script3 '$RUN_DIR/edit2.bin' --script3-after 'sh: monitor' --script-expect 'virelai-kernel' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'login: shell=sh -> SH.BIN'
vgate_assert 01 serial-contains 'sh: ready'
vgate_assert 01 serial-contains 'sh: attached'
vgate_assert 01 serial-contains 'sh: monitor'
vgate_assert 01 serial-contains 'virelai-kernel'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
i_ready = ser.find("sh: ready")
i_mon = ser.find("sh: monitor")
i_ver = ser.find("virelai-kernel")
assert i_ready >= 0 and i_mon >= 0 and i_ver >= 0, "missing marker(s)"
assert i_ready < i_mon < i_ver, f"wrong order ready={i_ready} monitor={i_mon} version={i_ver}"
assert "login: shell=sh -> SH.BIN" in ser, "the login handoff did not run"
print("monitor escape ordering OK: sh: ready < sh: monitor < virelai-kernel")
PY
