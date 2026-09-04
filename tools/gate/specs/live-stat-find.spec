# live-stat-find.spec -- M22 D8: stat + find filesystem inspection on VZ.
# Proves stat reports file metadata (size, regular file, host share volume)
# on bare and /-prefixed paths, and find recursively walks / on the host share
# matching known root binaries (*.BIN).

vgate_name live-stat-find "M22 D8: stat + find filesystem inspection on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
stat KERNEL.BIN
stat /KERNEL.BIN
find / -name "*.BIN"
echo rx-statfind-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-statfind-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains '  File:    KERNEL.BIN'
vgate_assert 01 serial-contains 'regular file'
vgate_assert 01 serial-contains '  Volume:  host share'
vgate_assert 01 serial-contains '/KERNEL.BIN'
vgate_assert 01 serial-contains 'rx-statfind-ok'
vgate_assert 01 serial-absent '[EXC] parking'

vgate_assert 01 python <<'PY'
import re, sys, os
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
matches = re.findall(r"^/[A-Za-z0-9_]+\.BIN$", ser, flags=re.MULTILINE)
if len(matches) < 2:
    sys.exit(f"ERROR: find count {len(matches)} < 2")
print(f"stat-find ok: found {len(matches)} *.BIN matches under /")
PY
