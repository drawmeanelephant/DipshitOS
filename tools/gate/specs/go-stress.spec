# go-stress.spec -- issue #1227 / M65c (#1441): GOOS=virelai 0b breadth
# (GC / channel / timer / futex) past the N=8 D6 baseline, on the
# compiled default GOMAXPROCS (no env pin — numCPUStartup = 2).
#
# The fixture (tools/go/gostress.go) prints one completion line per phase
# so this run is assert-proven by program output, not a script echo:
#   1. GC — 120 × 64 KiB churn, 8 live retainers, two runtime.GC() cycles
#   2. channel fan-out — 8 workers, 32 jobs, recv=32 sum=992
#   3. timer pacing — 8 × time.Sleep(10ms), elapsed >= 10ms
#   4. futex — 32 goroutines × 50 mutex increments (counter=1600) plus
#      park-all-then-wake; N=32 is past goroutines.go's N=8
#
# M65c drops `set GOMAXPROCS=2` so this gate proves the compiled default
# (ADR 0027 D6). `go-args` keeps GOMAXPROCS=1 as the env-override proof.
#
# HOST PREREQUISITE (not hermetic — see tools/go/README.md):
# `just go-toolchain` must have produced .build/go/GOSTRESS.ELF.
#
# exec-order: assert-proven -- --script2-after waits on the program's
# `go-stress done` line, then script2's echo ends the run; asserts read
# the program's own phase lines, so a green run always proves it ran.

vgate_name go-stress "issue #1227: GOOS=virelai GC/channel/timer/futex stress on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOSTRESS.ELF
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo gostress-held-window
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GOSTRESS.ELF")
if not os.path.exists(src):
    sys.exit("GOSTRESS.ELF missing (expected " + src + ") - "
             "build the fork binaries first: just go-toolchain "
             "(fork prerequisites in tools/go/README.md)")
shutil.copy(src, os.path.join(share, "GOSTRESS.ELF"))
print("staged GOSTRESS.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSTRESS.ELF")))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'go-stress done' --script-expect 'gostress-held-window' --timeout 120

vgate_assert 01 serial-contains 'exec: loaded GOSTRESS.ELF'
vgate_assert 01 serial-contains 'go-stress procs=2'
vgate_assert 01 serial-contains 'go-stress gc allocs=120 live=8'
vgate_assert 01 serial-contains 'go-stress chan fan=32 recv=32 sum=992'
vgate_assert 01 serial-contains 'go-stress timer n=8 ok'
vgate_assert 01 serial-contains 'go-stress futex n=32 counter=1600'
vgate_assert 01 serial-contains 'go-stress done'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def calls(slot):
    for l in lines:
        m = re.search(r"%d (sys_\w+) calls=(\d+)" % slot, l)
        if m:
            return int(m.group(2))
    return None
n_thread = calls(73)
if n_thread is None:
    sys.exit("FAIL: no sys_thread row in the syscalls report")
if n_thread < 2:
    sys.exit("FAIL: sys_thread calls >= 2 required, got %d" % n_thread)
n_futex = calls(74)
if n_futex is None or n_futex < 8:
    sys.exit("FAIL: sys_futex contention expected (>= 8 calls), got %s" % n_futex)
print("go-stress python asserts OK: sys_thread=%d sys_futex=%d" % (n_thread, n_futex))
PY
