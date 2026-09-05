# live-zc.spec -- M32 Lane 2: on-machine Zig subset compiler produces ELF loader runs

vgate_name live-zc "M32 Lane 2 -- compile ON the machine, run the output"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_py <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
shutil.copy("tests/zc-corpus/z3b-stdz.z", os.path.join(share, "APP.Z"))
shutil.copy("tests/zc-corpus/z3b-labels.z", os.path.join(share, "LABELS.Z"))
shutil.copy("user/src/lib/stdz/fmt.zig", os.path.join(share, "FMT.Z"))
shutil.copy("user/src/lib/stdz/string_builder.zig", os.path.join(share, "BUILDER.Z"))
shutil.copy("user/src/lib/stdz/ring.zig", os.path.join(share, "RING.Z"))
with open(os.path.join(share, "DATA.TXT"), "w") as f:
    f.write("hello world\nfoo bar baz\n")
with open(os.path.join(share, "REPORT.EXP"), "w") as f:
    f.write("bytes=24\nlines=2\nwords=5\nhex=18\n")
PY

vgate_file script.txt <<'EOF'
ls
strace exec ZC.BIN APP.Z LABELS.Z FMT.Z BUILDER.Z RING.Z MAIN.ELF
EOF

vgate_file script2.txt <<'EOF'
ls
exec MAIN.ELF
echo rx-zc-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "zc: successfully compiled in-guest" --script-expect "tasks user-exec exited status=72" --timeout 90

vgate_assert 01 serial-contains "VirelaiOS kernel has seized control."
vgate_assert 01 serial-contains "APP.Z"
vgate_assert 01 serial-contains "RING.Z"
vgate_assert 01 serial-contains "zc: successfully compiled in-guest"
vgate_assert 01 serial-contains "exec: loaded MAIN.ELF size="
vgate_assert 01 serial-contains "z3b-start"
vgate_assert 01 serial-contains "z3b-ok"
vgate_assert 01 serial-contains "tasks user-exec exited status=72"
vgate_assert 01 serial-contains "tasks user-exec reaped"
vgate_assert 01 serial-contains "rx-zc-ok"
vgate_assert 01 serial-contains "smp: secondary runs="
vgate_assert 01 serial-absent "[EXC] parking:"
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"]).read()
pos_start = ser.find("z3b-start")
pos_ok = ser.find("z3b-ok")
assert pos_start != -1 and pos_ok != -1 and pos_start < pos_ok, "markers unordered"
# byte-exact comparison of OUT.TXT to REPORT.EXP
out_p = os.path.join(share, "OUT.TXT")
exp_p = os.path.join(share, "REPORT.EXP")
assert os.path.exists(out_p), "OUT.TXT missing"
assert open(out_p, "rb").read() == open(exp_p, "rb").read(), "OUT.TXT != REPORT.EXP"
PY
