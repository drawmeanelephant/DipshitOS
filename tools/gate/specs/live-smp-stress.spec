# live-smp-stress.spec -- M28 SMP card 11 (claim 0697) class-B gate:
# 4 cores concurrently hammering 4 subsystems on real VZ.

vgate_name live-smp-stress "M28 SMP card 11 -- 4-core multi-subsystem concurrency stress"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
smp
net ip 10.0.0.1
exec -c1 SMPFILE.BIN
exec -c2 SMPNET.BIN
exec -c3 SMPWIN.BIN
exec -c0 SMPEV.BIN
echo rx-smpst-ok
EOF

# The FILE hammer's fixture (the READ side of its round trips): legacy
# planted it in the share with no trailing newline (40 bytes) — the
# hammer's read-length assertion; see user/src/smpst_file.zig `fixture`.
vgate_setup_python <<'PYEOF'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
with open(os.path.join(share, "STRESS.TXT"), "wb") as f:
    f.write(b"smpst stress fixture 0123456789abcdefghi")
PYEOF

vgate_run 01 -- --cpus 4 --screen '$RUN_DIR/screen' --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'smp: cores=4 online=4'
vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'exec: loaded SMPFILE.BIN size='
vgate_assert 01 serial-contains 'exec: loaded SMPNET.BIN size='
vgate_assert 01 serial-contains 'exec: loaded SMPWIN.BIN size='
vgate_assert 01 serial-contains 'exec: loaded SMPEV.BIN size='
vgate_assert 01 serial-count 'smpfile: hb=' 6
vgate_assert 01 serial-count 'smpnet: hb=' 6
vgate_assert 01 serial-count 'smpwin: hb=' 6
vgate_assert 01 serial-count 'smpev: ev=' 6
vgate_assert 01 serial-exact 'smpfile: done ops=24' 1
vgate_assert 01 serial-exact 'smpnet: done ops=24' 1
vgate_assert 01 serial-exact 'smpwin: done presents=12' 1
vgate_assert 01 serial-exact 'smpev: done events=6' 1
vgate_assert 01 serial-exact 'tasks user-exec exited status=0' 4
vgate_assert 01 serial-exact 'tasks user-exec reaped' 4
vgate_assert 01 serial-contains 'smp: secondary runs='
vgate_assert 01 serial-contains 'task=SMPFILE.BIN'
vgate_assert 01 serial-contains 'task=SMPNET.BIN'
vgate_assert 01 serial-contains 'task=SMPWIN.BIN'
vgate_assert 01 serial-contains 'rx-smpst-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
