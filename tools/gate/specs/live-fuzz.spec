# live-fuzz.spec -- M70a-live (#1466) / M70a3 (#1470): in-guest EL0
# syscall sweep plus live HF-wire STAT/mutations on queue 5.
#
# Distinct boot proof from live-hardening (window isolation vs a seeded
# trap-path corpus). Guest work is the `fuzz roster` command; typically
# well under; 90s timeout covers host stalls. Assert-proven: the run reads
# the program's own `seed=0x… ok` / `fuzz: caller-not-moved ok` /
# `fuzz: done` lines, not a script echo.
#
# Skip list (live-only, named): write/yield/exit/sleep/wait/udp_recv/
# wait_event/kill/tcp_connect/tcp_recv/setrlimit/thread/futex/sock_ready
# — they block, reap the caller, or sit on the kernel's 30 s TCP clock.
# Reply-byte mutations stay host-side (PR #1464); this spec mutates
# guest→host requests and proves the STAT `[size][type]` parse live.

# exec-order: assert-proven -- script waits for the boot USER.BIN reap
# (`tasks user-el0 exited status=7`) before typing `fuzz roster`; script2
# waits on the program's own `fuzz: done` and asserts seed-ok /
# caller-not-moved / wire lines the program (and the monitor command) print.

vgate_name live-fuzz "M70a-live #1466: in-guest EL0 sweep + live HF-wire corpus on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
fuzz roster
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo live-fuzz-held
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'fuzz: done' --script-expect 'live-fuzz-held' --timeout 90

vgate_assert 01 serial-contains 'fuzz: wire-stat USER.BIN ok=1'
vgate_assert 01 serial-contains 'fuzz: wire seed=0x5eed0001 decoded=32 violations=0'
vgate_assert 01 serial-contains 'fuzz: wire seed=0x13372026 decoded=32 violations=0'
vgate_assert 01 serial-contains 'fuzz: wire seed=0xdeadbeefcafe decoded=32 violations=0'
vgate_assert 01 serial-contains 'fuzz: wire seed=0xf0f12345678 decoded=32 violations=0'
vgate_assert 01 serial-contains 'fuzz: buffer EFAULT='
vgate_assert 01 serial-contains 'fuzz: caller-not-moved ok'
vgate_assert 01 serial-contains 'el0-exec: parent survived'
vgate_assert 01 serial-contains 'seed=0x5eed0001 ok'
vgate_assert 01 serial-contains 'seed=0x13372026 ok'
vgate_assert 01 serial-contains 'seed=0xdeadbeefcafe ok'
vgate_assert 01 serial-contains 'seed=0xf0f12345678 ok'
vgate_assert 01 serial-contains 'fuzz: done'
vgate_assert 01 serial-contains 'live-fuzz-held'
vgate_assert 01 serial-absent 'fuzz: VIOLATION'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'fuzz: bad seed'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
joined = "\n".join(lines)
need = (
    "fuzz: caller-not-moved ok",
    "fuzz: done",
    "seed=0x5eed0001 ok",
    "seed=0x13372026 ok",
    "seed=0xdeadbeefcafe ok",
    "seed=0xf0f12345678 ok",
)
missing = [n for n in need if n not in joined]
if missing:
    sys.exit("FAIL: live-fuzz markers missing: %s" % missing)
ok_lines = [l for l in lines if l.startswith("seed=0x") and " ok " in l]
if len(ok_lines) < 4:
    sys.exit("FAIL: expected 4 seed-ok lines, got %d: %s" % (len(ok_lines), ok_lines))
viol = [l for l in lines if "fuzz: VIOLATION" in l]
if viol:
    sys.exit("FAIL: violations: %s" % viol[:8])
print("live-fuzz markers ok seeds=%d" % len(ok_lines))
PY
