# live-svc.spec -- numbered syscall table dispatched through real EL0
# SVC: write/yield/exit counts, the userspace row, and write -> timer-irq
# -> exit line ordering. Mirrors tools/verify-live-svc.sh (claim 3594).
# Ordering is custom line-number logic in the original, so it rides the
# python escape hatch (see SPEC.md).

vgate_name live-svc "syscall table on EL0 SVC + write/irq/exit order"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: syscalls / echo rx-svc-ok"

vgate_file script.txt <<'EOF'
syscalls
echo rx-svc-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect "rx-svc-ok"$'\n' --timeout 45

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'syscall: write ok n=23' 1
vgate_assert 01 serial-exact '  0 sys_ping calls=2' 1
vgate_assert 01 serial-exact '  1 sys_write calls=3' 1
vgate_assert 01 serial-exact '  2 sys_yield calls=1' 1
vgate_assert 01 serial-exact 'tasks user-el0 exited status=7' 1
vgate_assert 01 serial-exact '  3 sys_exit calls=1' 1
vgate_assert 01 serial-exact 'rx-svc-ok' 1
vgate_assert 01 serial-exact 'userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first(needle):
    for i, l in enumerate(lines):
        if needle in l:
            return i
    return None
w = first("syscall: write ok n=23")
t = first("timer irq delivered ppi=0x1e irq_ticks=1")
e = first("tasks user-el0 exited status=7")
if w is None or t is None or e is None:
    sys.exit("FAIL: ordering needles absent w=%s t=%s e=%s" % (w, t, e))
if not (w < t < e):
    sys.exit("FAIL: write/irq/exit out of order w=%s t=%s e=%s" % (w, t, e))
print("order ok: write @%d < irq @%d < exit @%d" % (w, t, e))
PY
